! copyright info:
!
!                             @Copyright 2022
!                           Fireball Committee
! Hong Kong Quantum AI Laboratory, Ltd. - James P. Lewis, Chair
! Universidad de Madrid - Jose Ortega
! Academy of Sciences of the Czech Republic - Pavel Jelinek
! Arizona State University - Otto F. Sankey

! Previous and/or current contributors:
! Auburn University - Jian Jun Dong
! California Institute of Technology - Brandon Keith
! Czech Institute of Physics - Prokop Hapala
! Czech Institute of Physics - Vladimír Zobač
! Dublin Institute of Technology - Barry Haycock
! Pacific Northwest National Laboratory - Kurt Glaesemann
! University of Texas at Austin - Alex Demkov
! Ohio University - Dave Drabold
! Synfuels China Technology Co., Ltd. - Pengju Ren
! Washington University - Pete Fedders
! West Virginia University - Ning Ma and Hao Wang
! also Gary Adams, Juergen Frisch, John Tomfohr, Kevin Schmidt,
!      and Spencer Shellman

!
! RESTRICTED RIGHTS LEGEND
! Use, duplication, or disclosure of this software and its documentation
! by the Government is subject to restrictions as set forth in subdivision
! { (b) (3) (ii) } of the Rights in Technical Data and Computer Software
! clause at 52.227-7013.

! M_assemble_usr
! Module Description
! ===========================================================================
!>       This is a module containing all of the assembler programs required
!! to assemble the short range interactions related to the Hartree energies.
!! It contains the following subroutines within the module:
!!
!!       assemble_uee - assemble the double counting Hartree energy
!!       assemble_uxc - assemble the double counting xc correction
!!
! ===========================================================================
        module M_assemble_usr

! /GLOBAL
        use M_assemble_blocks

! /SYSTEM
        use M_configuraciones

! /FDATA
        use M_Fdata_1c
        use M_Fdata_2c

! module procedures
        contains

! ===========================================================================
! assemble_uee.f90
! ===========================================================================
! Subroutine Description
! ===========================================================================
!>       This routine calculates all the double counting corrections to the
!! Hartree interactions and is stored in uee.
! ===========================================================================
! Code written by:
! James P. Lewis
! Unit 909 of Buidling 17W
! 17 Science Park West Avenue
! Pak Shek Kok, New Territories 999077
! Hong Kong
!
! Phone: +852 6612 9539 (mobile)
! ===========================================================================
!
! Program Declaration
! ===========================================================================
        subroutine assemble_uee (s, uii_uee)
        implicit none

        include '../include/constants.h'

! Argument Declaration and Description
! ===========================================================================
        type(T_structure), target :: s  !< type structure

        real uii_uee           !< double counting correction for coulomb part

! Parameters and Data Declaration
! ===========================================================================
! None

! Variable Declaration and Description
! ===========================================================================
        integer iatom, ineigh            !< counter over atoms and neighbors
        integer in1, in2                 !< species numbers
        integer jatom                    !< neighbor of iatom
        integer interaction, isubtype    !< which interaction and subtype
        integer logfile                     !< writing to which unit
        integer num_neigh                !< number of neighbors
        integer mbeta                    !< the cell containing iatom's neighbor
        integer issh, jssh               !< counting over orbitals
        integer norb_mu, norb_nu         !< size of the block for the pair

        real eklr                         !< long-range ewald correction
        real u0_tot                       !< total neutral atom correction
        real uee_self_tot                 !< self-energy correction
        real z                            !< distance between atom pairs
        real Zi, Zj

        real, allocatable :: coulomb (:, :)
        real, allocatable :: Q0 (:)    !< total neutral atom charge, i.e. Ztot
        real, allocatable :: Q(:)      !< total charge on atom
        real, dimension (3) :: r1, r2
        real, allocatable :: uee_self (:)

        interface
          function distance (a, b)
            real distance
            real, intent (in), dimension (3) :: a, b
          end function distance
        end interface

        type(T_assemble_neighbors), pointer :: u0 (:)
        type(T_assemble_neighbors), pointer :: corksr (:)

! Allocate Arrays
! ===========================================================================
        allocate (u0 (s%natoms))             !< neutral atom uee
        allocate (corksr (s%natoms))         !< short range ewald correction
        allocate (uee_self (s%natoms))       !< self-interaction for uee
        allocate (Q0 (s%natoms))             !< neutral atom charge, i.e. ionic
        allocate (Q (s%natoms))              !< total input charge on atom

! Procedure
! ===========================================================================
! Initialize logfile
        logfile = s%logfile
        write (logfile,*) ' Welcome to assemble_usr.f! '

! Initialize arrays
        u0_tot = 0.0d0
        uee_self_tot = 0.0d0
        ! Calculate nuclear charge.
        do iatom = 1, s%natoms
          in1 = s%atom(iatom)%imass
          Q0(iatom) = 0.0d0
          Q(iatom) = 0.0d0
          do issh = 1, species(in1)%nssh
            Q0(iatom) = Q0(iatom) + species(in1)%shell(issh)%Qneutral
            Q(iatom) = Q(iatom) + s%atom(iatom)%shell(issh)%Qin
          end do
        end do

! Loop over the atoms in the central cell.
        do iatom = 1, s%natoms
          r1 = s%atom(iatom)%ratom
          in1 = s%atom(iatom)%imass
          norb_mu = species(in1)%nssh
          num_neigh = s%neighbors(iatom)%neighn
          allocate (u0(iatom)%neighbors(num_neigh))
          allocate (corksr(iatom)%neighbors(num_neigh))
          Zi = Q0(iatom)

! Loop over the neighbors of each iatom.
          do ineigh = 1, num_neigh  ! <==== loop over i's neighbors
            mbeta = s%neighbors(iatom)%neigh_b(ineigh)
            jatom = s%neighbors(iatom)%neigh_j(ineigh)
            r2 = s%atom(jatom)%ratom + s%xl(mbeta)%a
            in2 = s%atom(jatom)%imass
            norb_nu = species(in2)%nssh
            Zj = Q0(jatom)

            ! distance between the two atoms
            z = distance (r1, r2)

! GET COULOMB INTERACTIONS
! ****************************************************************************
! Now find the three coulomb integrals need to evaluate the neutral
! atom/neutral atom hartree interaction.
! For these Harris interactions, there are no subtypes and isorp = 0
            isubtype = 0
            interaction = P_coulomb

            allocate (coulomb (norb_mu, norb_nu))
            call getMEs_Fdata_2c (in1, in2, interaction, isubtype, z,         &
     &                            norb_mu, norb_nu, coulomb)

! Actually, now we calculate not only the neutral atom contribution,
! but also the short-ranged contribution due to the transfer of charge
! between the atoms:
!
! (Eii - Eee)neut - SUM(short range)(n(i) + dn(i))*dn(j)*J(i,j),
            if (iatom .eq. jatom .and. mbeta .eq. 0) then

! SPECIAL CASE: SELF-INTERACTION
              uee_self(iatom) = 0.0d0
              do issh = 1, species(in1)%nssh
                do jssh = 1, species(in1)%nssh
                  uee_self(iatom) =  uee_self(iatom)                          &
     &              + (P_eq2/2.0d0)*s%atom(iatom)%shell(issh)%Qin             &
     &                             *s%atom(iatom)%shell(jssh)%Qin*coulomb(issh,jssh)
                end do
              end do

! put the half and the units in:
              u0(iatom)%neighbors(ineigh)%E = 0.0d0
              corksr(iatom)%neighbors(ineigh)%E = 0.0d0
            else

! BONAFIDE TWO ATOM CASE
! Compute u0
              u0(iatom)%neighbors(ineigh)%E = 0.0d0
              do issh = 1, species(in1)%nssh
                do jssh = 1, species(in2)%nssh
                  u0(iatom)%neighbors(ineigh)%E =                             &
     &              u0(iatom)%neighbors(ineigh)%E                             &
     &               + s%atom(iatom)%shell(issh)%Qin                          &
     &                *s%atom(jatom)%shell(jssh)%Qin*coulomb(issh,jssh)
                end do
              end do
              u0(iatom)%neighbors(ineigh)%E =                                 &
     &         (P_eq2/2.0d0)*(Zi*Zj/z - u0(iatom)%neighbors(ineigh)%E)
              corksr(iatom)%neighbors(ineigh)%E =                             &
     &          - (P_eq2/2.0d0)*(Zi*Zj - Q(iatom)*Q(jatom))/z
            end if ! end if for r1 .eq. r2 case
            deallocate (coulomb)

! Compute the total cell value of uii-uee; uii-uee = sum u0(i,m) - sum uee00(i)
!           u0_tot = u0_tot + u0(iatom)%neighbors(ineigh)%E
            u0_tot = u0_tot + u0(iatom)%neighbors(ineigh)%E                   &
     &                      + corksr(iatom)%neighbors(ineigh)%E
          end do ! end loop over neighbors
          uee_self_tot = uee_self_tot + uee_self(iatom)
        end do ! end loop over atoms

! Notice that we add the corksr correction to etot.
! This is because of the subtraction minus discussed above.
        eklr = 0.0d0
        do iatom = 1, s%natoms
          Zi = Q0(iatom)
          do jatom = iatom, s%natoms
             Zj = Q0(jatom)

! Calculate q(iatom)*q(jatom) - q0(iatom)*q0(jatom) = QQ
            if (iatom .eq. jatom) then
               eklr = eklr - (P_eq2/2.0d0)*s%ewald(iatom,jatom)               &
      &                                   *(Zi*Zj - Q(iatom)*Q(jatom))
            else
               eklr = eklr - (P_eq2/2.0d0)*s%ewald(iatom,jatom)               &
      &                                   *(Zi*Zj - Q(iatom)*Q(jatom))        &
      &                    - (P_eq2/2.0d0)*s%ewald(jatom,iatom)               &
      &                                   *(Zi*Zj - Q(iatom)*Q(jatom))
            end if
          end do
        end do
        u0_tot = u0_tot - eklr

        ! Final double-counting correction for coulomb part
        uii_uee = u0_tot - uee_self_tot

! Deallocate Arrays
! ===========================================================================
        deallocate (Q, Q0, uee_self)
        do iatom = 1, s%natoms
          deallocate (u0(iatom)%neighbors)
          deallocate (corksr(iatom)%neighbors)
        end do
        deallocate (u0)
        deallocate (corksr)

! Format Statements
! ===========================================================================
! None

! End Subroutine
! ===========================================================================
        return
        end subroutine assemble_uee


!===========================================================================
! assemble_uxc
! ===========================================================================
! Subroutine Description
! ===========================================================================
!>       This routine calculates the exchange-correlation double-counting
!! energy for McWEDA (Harris).
!
! We use a finite difference approach to change the densities and then
! find the corresponding changes in the exchange-correlation potential.
! This a bit clumsy sometimes, and probably can use a rethinking to improve.
! However, it actually works quite well for many molecular systems.
!
! We compute neutral cases for ideriv = 1. For other ideriv's we have the
! following KEY:
!
! Case 1 (KEY=1), neutral neutral corresponds to (00)
! KEY = 1,2,3,4,5 for ideriv = 1,2,3,4,5
!
! For the one-center case we only use ideriv = 1,2,3 as there is only one atom.
!
!                                   |
!                                   + (0+) KEY=5
!                                   |
!                                   |
!                                   |
!                       KEY=2       |  KEY=1
!                      (-0)         |(00)        (+0) KEY=3
!                     --+-----------O-----------+--
!                                   |
!                                   |
!                                   |
!                                   |
!                                   |
!                                   +(0-) KEY=4
!                                   |
! ===========================================================================
! Code written by:
!> @author Daniel G. Trabada
!! @author Jose Ortega (JOM)
! Departamento de Fisica Teorica de la Materia Condensada
! Universidad Autonoma de Madrid
! ===========================================================================
!
! Program Declaration
! ===========================================================================
        subroutine assemble_uxc (s, uxcdcc)
        implicit none

! Argument Declaration and Description
! ===========================================================================
! Input
        type(T_structure), target :: s           !< the structure to be used.

! Output
        real uxcdcc           !< double counting correction for coulomb part

! Parameters and Data Declaration
! ===========================================================================
! None

! Variable Declaration and Description
! ===========================================================================
        integer iatom, ineigh             !< counter over atoms and neighbors
        integer ispecies, in1, in2        !< species numbers
        integer jatom                     !< neighbor of iatom
        integer interaction, isubtype     !< which interaction and subtype
        integer num_neigh                 !< number of neighbors
        integer mbeta                     !< the cell containing iatom's neighbor

        integer issh                      !< counting over orbitals
        integer norb_mu, norb_nu          !< size of the block for the pair

        ! different derivative cases
        integer ideriv, ideriv_min, ideriv_max

! Some parameters for the derivative parts:
        integer, parameter, dimension (0:4) :: jsign = (/0, -1, +1, -1, +1/)
        integer, parameter, dimension (0:4) :: kspecies_key = (/1, 1, 1, 2, 2/)

        real z                           !< distance between atom pairs

! The charge transfer bit = need a +-dq on each orbital.
        real, allocatable :: dqorb (:)
        real, allocatable :: dQ (:)    !< charge on atom, i.e. ionic
        real, allocatable :: Q0 (:)    !< total neutral atom charge, i.e. Ztot
        real, allocatable :: Q (:)     !< total charge on atom

        ! quadratic fitting factors
        real, dimension (0:2) :: dQ_linear
        real, dimension (0:2) :: dQ_quadratic
        real, dimension (0:2) :: dQ_factor

        real, dimension (3) :: r1, r2

        ! results
        real exc_1c, uxcdc_bond
        real, dimension (0:4) :: uxc

        interface
          function distance (a, b)
            real distance
            real, intent (in), dimension (3) :: a, b
          end function distance
        end interface

! Allocate Arrays
! ===========================================================================
        allocate (dqorb (nspecies))
        allocate (Q0 (s%natoms))
        allocate (Q (s%natoms))
        allocate (dQ (s%natoms))

! Procedure
! ===========================================================================
! Initialize
        exc_1c = 0.0d0; uxcdc_bond = 0.0d0

! Initialize the charge transfer bit
        do ispecies = 1, nspecies
          dqorb(ispecies) = 0.5d0
          if (species(ispecies)%nssh .eq. 1) dqorb(ispecies) = 0.25d0
        end do

! Calculate nuclear charge.
        do iatom = 1, s%natoms
          in1 = s%atom(iatom)%imass
          Q0(iatom) = 0.0d0
          Q(iatom) = 0.0d0
          do issh = 1, species(in1)%nssh
            Q0(iatom) = Q0(iatom) + species(in1)%shell(issh)%Qneutral
            Q(iatom) = Q(iatom) + s%atom(iatom)%shell(issh)%Qin
          end do
          dQ(iatom) = Q(iatom) - Q0(iatom)
        end do

! Loop over the atoms in the central cell.
        do iatom = 1, s%natoms
          r1 = s%atom(iatom)%ratom
          in1 = s%atom(iatom)%imass
          num_neigh = s%neighbors(iatom)%neighn

! One-center Piece
! ****************************************************************************
! We do a quadratic expansion:
!       f(q) = f(0)  +  f'(0)*q   +  1/2 f''(0)*q*q
!
! The derivatives are computed as:
!       f'(0)  = [ f(dq) - f(-dq) ] / 2dq
!       f''(0) = [ f(dq) - 2f(0) + f(-dq) ] / dq*dq
!
! We introduce linear factors:
!              linfac(0)   =  1.0
!              linfac(i)   =  -/+ * (1/2) *  q/dq        i = 1, 2
!
!    and quadratic factors:
!              quadfac(0)  = -2.0 * (1/2) * (q/dq)**2
!              quadfac(i)  =  1.0 * (1/2) * (q/dq)**2    i=1,2
!
!       f(0) = f(dq=0) ; f(1) = f(-dq) ; f(2) = f(dq)
!
! With this, f(q) is given as:
!       f(q) = sum_i  (linfac(i) + quadfac(i))*f(i)
!
! ****************************************************************************
          dQ_linear(0) = 1.0d0
          dQ_linear(1) = -0.5d0*dQ(iatom)/dqorb(in1)
          dQ_linear(2) =  0.5d0*dQ(iatom)/dqorb(in1)

          dQ_quadratic(1) =  0.5d0*(dQ(iatom)/dqorb(in1))**2
          dQ_quadratic(2) =  0.5d0*(dQ(iatom)/dqorb(in1))**2
          dQ_quadratic(0) = -1.0d0*(dQ(iatom)/dqorb(in1))**2

          dQ_factor = dQ_linear + dQ_quadratic

! Calculate exc_bond : energy from first one center piece of exchange-
! correlation already included in the band-structure through vxc_1c
          exc_1c = exc_1c + dQ_factor(0)*vxc_1c(in1)%E

! Loop over the different derivative types. We already did ideriv=0 case.
! Set ideriv_min = 1 and ideriv_max = 2 for one center case.
          ideriv_min = 1
          ideriv_max = 2
          do ideriv = ideriv_min, ideriv_max
            exc_1c = exc_1c + dQ_factor(ideriv)*vxc_1c(in1)%dE(ideriv)
          end do

! Loop over the neighbors of each iatom.
          do ineigh = 1, num_neigh  ! <==== loop over i's neighbors
            mbeta = s%neighbors(iatom)%neigh_b(ineigh)
            jatom = s%neighbors(iatom)%neigh_j(ineigh)
            r2 = s%atom(jatom)%ratom + s%xl(mbeta)%a
            in2 = s%atom(jatom)%imass

            ! distance between the two atoms
            z = distance (r1, r2)

! GET DOUBLE-COUNTING EXCHANGE-CORRELATION INTERACTIONS
! ****************************************************************************
! Now find the value of the integrals needed to evaluate the neutral
! atom/neutral atom exchange-correlation double-counting interaction.
!
! Now we should interpolate - the fast way is:
!
!   e(dqi,dqj) = exc(0,0) + dqi*(exc(1,0) - exc(0,0))/dQ
!                         + dqj*(exc(0,1) - exc(0,0))/dQ
!
! The good way is to use a three point Lagrange interpolation along the axis.
!
! Lagrange: f(x) = f(1)*L1(x) + f(2)*L2(x) + f(3)*L3(x)
!
! L1(x) = (x - x2)/(x1 - x2)*(x - x3)/(x1 - x3)
! L2(x) = (x - x3)/(x2 - x1)*(x - x3)/(x2 - x3)
! L3(x) = (x - x1)/(x3 - x1)*(x - x2)/(x3 - x2)
!
! in our case:
!
! L1(dq) = (1/2)*dq*(dq - 1)
! L2(dq) = -(dq + 1)*(dq - 1)
! L3(dq) = (1/2)*dq*(dq + 1)
!
! The interpolation does not depend on the (qi,qj) quadrant:
!
!  f(dqi,dqj) = f(0,dqj) + f(dqi,0) - f(0,0)
! ****************************************************************************
            if (iatom .eq. jatom .and. mbeta .eq. 0) then

! SPECIAL CASE: SELF-INTERACTION - do nothing here

            else

              isubtype = 0
              interaction = P_uxc

              ! we set norb_mu = 1 and norb_nu = 1 because this interaction
              ! is not a matrix, but rather just a energy based on distances
              norb_mu = 1
              norb_nu = 1
              call getMEs_Fdata_2c (in1, in2, interaction, isubtype, z,       &
     &                              norb_mu, norb_nu, uxc(0))

              ! add the uxc from interpolation to the total
              uxcdc_bond = uxcdc_bond + uxc(0)

! Loop over the different derivative types. We already did ideriv=0 case.
! Set ideriv_min = 1 and ideriv_max = 2 for one center case.
              ideriv_min = 1
              ideriv_max = 4

              ! Now loop over the different ideriv subtypes
              do ideriv = ideriv_min, ideriv_max
                isubtype = ideriv
                call getMEs_Fdata_2c (in1, in2, interaction, isubtype, z,     &
     &                                norb_mu, norb_nu, uxc(isubtype))
              end do

              ! add the uxc from interpolation to the total
              ! First, we look at the sign of the charge and "pick" the
              ! correct differences to add accordingly
              if (dQ(iatom) .gt. 0.0d0 .and. dQ(jatom) .gt. 0.0d0) then
                uxcdc_bond = uxcdc_bond + dQ(iatom)*(uxc(2) - uxc(0))/dqorb(in1)&
     &                                  + dQ(jatom)*(uxc(4) - uxc(0))/dqorb(in2)
              else if (dQ(iatom) .lt. 0.0d0 .and. dQ(jatom) .lt. 0.0d0) then
                uxcdc_bond = uxcdc_bond + dQ(iatom)*(uxc(0) - uxc(1))/dqorb(in1)&
     &                                  + dQ(jatom)*(uxc(0) - uxc(3))/dqorb(in2)
              else if (dQ(iatom) .gt. 0.0d0 .and. dQ(jatom) .lt. 0.0d0) then
                uxcdc_bond = uxcdc_bond + dQ(iatom)*(uxc(2) - uxc(0))/dqorb(in1)&
     &                                  + dQ(jatom)*(uxc(0) - uxc(3))/dqorb(in2)
              else if (dQ(iatom) .lt. 0.0d0 .and. dQ(jatom) .gt. 0.0d0) then
                uxcdc_bond = uxcdc_bond + dQ(iatom)*(uxc(0) - uxc(1))/dqorb(in1)&
     &                                  + dQ(jatom)*(uxc(4) - uxc(0))/dqorb(in2)
              end if
            end if ! end if for r1 .eq. r2 case
          end do ! end loop over neighbors
        end do ! end loop over atoms

        ! take half here to account for double counting in iatom, jatom loop
        uxcdcc = exc_1c + (uxcdc_bond/2.0d0)

! Deallocate Arrays
! ===========================================================================
        deallocate (dqorb, dQ, Q, Q0)

! Format Statements
! ===========================================================================
! None

! End Subroutine
! ===========================================================================
        return
        end subroutine assemble_uxc

! End Module
! ===========================================================================
        end module M_assemble_usr
