Require Import coqutil.Tactics.rdelta.
Require Import coqutil.Tactics.rewr.
Require Import coqutil.Datatypes.PropSet.
Require Import riscv.Spec.Decode.
Require Import riscv.Spec.Primitives.
Require Import riscv.Platform.RiscvMachine.
Require Import riscv.Platform.MetricRiscvMachine.
Require Import riscv.Platform.MetricLogging.
Require Import riscv.Utility.Utility.
Require Import riscv.Utility.runsToNonDet.
Require Import compiler.util.Common.
Require Import coqutil.Datatypes.ListSet.
Require Import coqutil.Datatypes.List.
Require Import compiler.Simp.
Require Import compiler.SeparationLogic.
Require Import compiler.SimplWordExpr.
Require Import compiler.GoFlatToRiscv.
Require Import compiler.DivisibleBy4.
Require Import compiler.MetricsToRiscv.
Require Import compiler.FlatImp.
Require Import compiler.RunInstruction.
Require Import compiler.FlatToRiscvDef.
Require Import compiler.FlatToRiscvCommon.
Require Import compiler.FlatToRiscvLiterals.
Require Import compiler.load_save_regs_correct.
Require Import compiler.eqexact.
Require Import compiler.RiscvWordProperties.
Require Import compiler.on_hyp_containing.
Require Import coqutil.Word.DebugWordEq.
Require Import compiler.MemoryLayout.
Require Import coqutil.Map.TestLemmas.

Import Utility MetricLogging.

(* indicates that if we were to replace blia by omega, we'd run out of heap, stack, or time *)
Ltac omega_safe ::= fail.

Section Proofs.
  Context {p: FlatToRiscvCommon.parameters}.
  Context {h: FlatToRiscvCommon.assumptions}.

  Add Ring wring : (word.ring_theory (word := word))
      (preprocess [autorewrite with rew_word_morphism],
       morphism (word.ring_morph (word := word)),
       constants [word_cst]).

  Local Notation RiscvMachineL := MetricRiscvMachine.

  Lemma framesize_nonneg: forall argvars resvars body,
      0 <= framelength (argvars, resvars, body).
  Proof.
    intros. unfold framelength.
    unfold bytes_per_word, Memory.bytes_per. blia.
  Qed.

  Lemma fits_stack_nonneg: forall n e s,
      fits_stack n e s ->
      0 <= n.
  Proof.
    induction 1; try blia. pose proof (@framesize_nonneg argnames retnames body). blia.
  Qed.

  (* high stack addresses     | stackframe of main             \
                              ...                               \
    g|                        ---                                }- stuffed into R
    r|                        | stackframe of current func      /
    o|              p_sp -->  ---                              /
    w|                        |
    s|                        | currently unused stack
     |                        | (old_stackvals)
     V                        |
            p_stacklimit -->  ---

     low stack addresses *)

  Notation fun_pos_env := (@funname_env p Z).

  Lemma functions_expose: forall base rel_positions impls f pos impl,
      map.get rel_positions f = Some pos ->
      map.get impls f = Some impl ->
      iff1 (functions base rel_positions impls)
           (functions base rel_positions (map.remove impls f) *
            program (word.add base (word.of_Z pos)) (compile_function rel_positions pos impl))%sep.
  Proof.
    intros. unfold functions.
    match goal with
    | |- context[map.fold ?F] => pose proof (map.fold_remove F) as P
    end.
    simpl in P.
    specialize P with (2 := H0).
    rewrite P.
    - unfold function at 1. rewrite H. cancel. reflexivity.
    - intros. apply iff1ToEq. cancel.
  Qed.

  Lemma modVars_as_list_valid_FlatImp_var: forall (s: stmt Z),
      valid_FlatImp_vars s ->
      Forall valid_FlatImp_var (modVars_as_list Z.eqb s).
  Proof.
    induction s; intros; simpl in *; simp; pose proof @union_Forall; eauto 10.
  Qed.

  Set Printing Depth 100000.

  Ltac tag P ::=
    let __ := lazymatch type of P with
              | @map.rep _ _ _ -> Prop => idtac
              | _ => fail 10000 P "is not a sep clause"
              end in
    lazymatch P with
    | array ptsto_instr _ _ (compile_stmt _ _ ?Code) => Code
    | ptsto_instr _ ?Instr => Instr
    | array ptsto_word _ _ ?Words => Words
    | functions _ _ ?E_Impl => E_Impl
    | _ => fail "no recognizable tag"
    end.

  Ltac addr P ::=
    let __ := lazymatch type of P with
              | @map.rep _ _ _ -> Prop => idtac
              | _ => fail 10000 P "is not a sep clause"
              end in
    lazymatch P with
    | array _ _ ?A _ => A
    | ptsto_instr ?A _ => A
    | ptsto_word ?A _ => A
    | _ => fail "no recognizable address"
    end.

  Ltac safe_sidecond :=
    match goal with
    (* proving these equalties with eq_refl will make other goals harder to prove,
       so we prefer to leave these open, so that they will become instantiated,
       and we can do interesting work here
    | |- ?L = _ => is_evar L; reflexivity
    | |- _ = ?R => is_evar R; reflexivity
      However, for some equalities, it's ok to prove them with eq_refl:
    *)
    | |- @eq ?T _ _ => first [ unify T (list Instruction) | unify T (@env (@Semantics_params p)) ];
                       reflexivity
    | H: fits_stack _ _ ?Code |- fits_stack _ _ ?Code => exact H
    | H: map.get ?R RegisterNames.sp = Some _ |- map.get ?R RegisterNames.sp = Some _ => exact H
    | |- ?G => assert_fails (has_evar G);
               solve [ simpl_addrs; solve_word_eq (@word_ok (@W (@def_params p)))
                     | solve_stmt_not_too_big
                     | reflexivity
                     | assumption
                     | solve_divisibleBy4
                     | solve_valid_machine (@word_ok (@W (@def_params p))) ]
    | H: subset (footpr _) _ |- subset (footpr _) _ =>
      eapply rearrange_footpr_subset; [ exact H | solve [wwcancel] ]
    | |- _ => solve [wcancel_assumption]
    | |- ?G => is_lia G; assert_fails (has_evar G);
               (* not sure why this line is needed, lia should be able to deal with (x := _) hyps,
                  maybe it changes some implicit args or universes? *)
               repeat match goal with x := _ |- _ => subst x end;
               blia
    end.

  Declare Scope word_scope.
  Notation "! n" := (word.of_Z n) (at level 0, n at level 0, format "! n") : word_scope.
  Notation "# n" := (Z.of_nat n) (at level 0, n at level 0, format "# n") : word_scope.
  Infix "+" := word.add : word_scope.
  Infix "-" := word.sub : word_scope.
  Infix "*" := word.mul : word_scope.
  Notation "- x" := (word.opp x) : word_scope.

  Delimit Scope word_scope with word.

  Open Scope word_scope.

  Lemma preserve_valid_FlatImp_var_domain_put: forall y z (l: locals),
      valid_FlatImp_var y ->
      (forall x v, map.get l x = Some v -> valid_FlatImp_var x) ->
      (forall x v, map.get (map.put l y z) x = Some v -> valid_FlatImp_var x).
  Proof.
    intros y z l V D x v G.
    rewrite map.get_put_dec in G.
    destr (y =? x).
    * subst. assumption.
    * eauto.
  Qed.

  Ltac run1done :=
    apply runsToDone;
    simpl_MetricRiscvMachine_get_set;
    simpl in *;
    repeat match goal with
    | |- exists (_: _), _ => eexists
    end;
    ssplit;
    simpl_word_exprs (@word_ok (@W (@def_params p)));
    match goal with
    | |- _ => solve_word_eq (@word_ok (@W (@def_params p)))
    | |- exists _, _ = _ /\ (_ * _)%sep _ =>
      eexists; split; cycle 1; [ wcancel_assumption | blia ]
    | |- _ => solve [rewrite ?of_list_list_union in *;
                     (* Don't do that, because it will consider all Zs as variables
                        and slow everything down
                        change Z with Register in *; *)
                     map_solver (@locals_ok p h)]
    | |- _ => solve [solve_valid_machine (@word_ok (@W (@def_params p)))]
    | |- _ => solve [epose proof regs_initialized_put; epose proof preserve_valid_FlatImp_var_domain_put; eauto 3]
    | H: subset (footpr _) _ |- subset (footpr _) _ =>
      eapply rearrange_footpr_subset; [ exact H | solve [wwcancel] ]
    | |- _ => idtac
    end.

  Ltac after_IH :=
    simpl_MetricRiscvMachine_get_set;
    simpl_g_get;
    rewrite ?@length_save_regs, ?@length_load_regs in *;
    unfold Register, MachineInt in *;
    simpl_word_exprs (@word_ok (@W (@def_params p)));
    repeat match goal with
           | |- _ /\ _ => split
           | |- exists _, _ => eexists
           end.

  Ltac sidecondition_hook ::=
    try solve [ map_solver (@locals_ok p h)
              | wcancel_assumption ].

  Lemma split_from_right{A: Type}: forall (l: list A) (len: nat),
      (len <= length l)%nat ->
      exists lL lR, l = lL ++ lR /\ length lL = (length l - len)%nat /\ length lR = len.
  Proof.
    intros.
    exists (List.firstn (List.length l - len)%nat l).
    exists (List.skipn (List.length l - len)%nat l).
    ssplit.
    - eapply List.firstn_skipn_reassemble; reflexivity.
    - rewrite List.length_firstn_inbounds; blia.
    - rewrite List.length_skipn; blia.
  Qed.

  Ltac split_from_right nameOrig nameL nameR len :=
    let nL := fresh in let nR := fresh in
    destruct (split_from_right nameOrig len) as [ nL [ nR [ ? [ ? ? ] ] ] ];
    [ blia | ];
    subst nameOrig;
    rename nL into nameL, nR into nameR.

  Lemma map_extends_remove: forall (m1 m2: funname_env (list Z * list Z * stmt Z)) k,
      map.extends m1 m2 ->
      map.extends m1 (map.remove m2 k).
  Proof.
    generalize (funname_env_ok (list Z * list Z * stmt Z)).
    simpl in *.
    unfold Register, MachineInt in *.
    intro OK.
    map_solver OK.
  Qed.

  Lemma map_get_Some_remove: forall (m: funname_env (list Z * list Z * stmt Z)) k1 k2 v,
      map.get (map.remove m k1) k2 = Some v ->
      map.get m k2 = Some v.
  Proof.
    generalize (funname_env_ok (list Z * list Z * stmt Z)).
    intro OK. intros. map_solver OK.
  Qed.

  Lemma pigeonhole{A: Type}{aeqb: A -> A -> bool}{aeqb_sepc: EqDecider aeqb}: forall (l s: list A),
      (* no pigeonhole contains more than one pigeon: *)
      NoDup l ->
      (* all elements in l are of "type" s (which is bounded by its finite length) *)
      (forall a, In a l -> In a s) ->
      (* "type" s is a set (to make induction simpler) *)
      NoDup s ->
      (* the number of pigeons is bounded: *)
      (List.length l <= List.length s)%nat.
  Proof.
    induction l; intros.
    - simpl. blia.
    - simpl. simp.
      specialize (IHl (removeb aeqb a s)).
      specialize_hyp IHl.
      + assumption.
      + intros.
        destr (aeqb a a0).
        * subst. contradiction.
        * apply In_removeb_diff; try congruence.
          eapply H0. simpl. auto.
      + apply NoDup_removeb. assumption.
      + specialize (H0 a (or_introl eq_refl)).
        rewrite length_NoDup_removeb in IHl by assumption.
        destruct s; [simpl in *; contradiction|].
        simpl in *. blia.
  Qed.

  Lemma NoDup_valid_FlatImp_vars_bound_length: forall xs,
      NoDup xs ->
      Forall valid_FlatImp_var xs ->
      (Datatypes.length xs <= 29)%nat.
  Proof.
    intros.
    apply (pigeonhole xs (List.unfoldn Z.succ 29 3) H).
    - intros.
      eapply (proj1 (Forall_forall valid_FlatImp_var xs)) in H0.
      2: eassumption.
      unfold valid_FlatImp_var in *.
      cbv. blia.
    - cbv. repeat apply NoDup_cons; cbv; try blia.
      apply NoDup_nil.
  Qed.

  Lemma NoDup_modVars_as_list: forall s,
      NoDup (modVars_as_list Z.eqb s).
  Proof.
    induction s; simpl; repeat constructor; try (intro C; exact C); try (eapply list_union_preserves_NoDup;
      eassumption || constructor).
  Qed.

  Ltac clear_old_sep_hyps :=
    repeat match goal with
           | H1: (_ * _)%sep ?m1, H2: (_ * _)%sep ?m2 |- _ => clear H1
           end.

  Ltac getEq_length_load_save_regs t :=
    match t with
    | context [ Datatypes.length (save_regs ?vars ?offset) ] =>
      constr:(length_save_regs vars offset)
    | context [ Datatypes.length (load_regs ?vars ?offset) ] =>
      constr:(length_load_regs vars offset)
    end.

  Ltac wseplog_pre ::=
    repeat (autounfold with unf_to_array);
    repeat ( rewr getEq_length_load_save_regs in |-* || rewr get_array_rewr_eq in |-* ).

  Lemma compile_stmt_correct:
    (forall resvars extcall argvars,
        compiles_FlatToRiscv_correctly
          compile_ext_call (SInteract resvars extcall argvars)) ->
    (forall s,
        compiles_FlatToRiscv_correctly
          compile_stmt s).
  Proof. (* by induction on the FlatImp execution, symbolically executing through concrete
     RISC-V instructions, and using the IH for lists of abstract instructions (eg a then or else branch),
     using cancellation, bitvector reasoning, lia, and firstorder for the sideconditions. *)
    intros compile_ext_call_correct.
    unfold compiles_FlatToRiscv_correctly.
    induction 1; intros; unfold goodMachine in *;
      destruct g as [p_sp num_stackwords p_insts insts program_base
                     e_pos e_impl funnames frame].
      all: repeat match goal with
                  | m: _ |- _ => destruct_RiscvMachine m
                  end.
      all: subst.
      all: simp.
      all: unfold Register, MachineInt in *.
    (*about this many lines should have been enough to prove this...*)

    - idtac "Case compile_stmt_correct/SInteract".
      eapply runsTo_weaken.
      + unfold compiles_FlatToRiscv_correctly in *.
        eapply compile_ext_call_correct with
            (postH := post) (g := {| program_base := program_base |}) (pos := pos)
            (extcall := action) (argvars := argvars) (resvars := resvars) (initialMH := m);
          simpl;
          clear compile_ext_call_correct.
        * econstructor; try eassumption.
        * eassumption.
        * econstructor. blia.
        * reflexivity.
        * eassumption.
        * split; assumption.
        * assumption.
        * assumption.
        * reflexivity.
        * reflexivity.
        * unfold goodMachine, valid_FlatImp_var in *. simpl. ssplit; eauto.
      + simpl. intros finalL A. destruct_RiscvMachine finalL. unfold goodMachine in *. simpl in *.
        destruct_products. subst.
        do 4 eexists; ssplit; eauto.

    - idtac "Case compile_stmt_correct/SCall".
      (* We have one "map.get e fname" from exec, one from fits_stack, make them match *)
      lazymatch goal with
      | H: good_reduced_e_impl _ _ _ _ |- _ => destruct H as (? & ?)
      end.
      unfold good_e_impl, valid_FlatImp_fun in *.
      simpl in *.
      simp.
      lazymatch goal with
      | H1: map.get e_impl_full fname = ?RHS1,
        H2: map.get e_impl fname = ?RHS2,
        H3: map.extends e_impl_full e_impl |- _ =>
        let F := fresh in assert (RHS1 = RHS2) as F
            by (clear -H1 H2 H3;
                unfold map.extends in H3;
                specialize H3 with (1 := H2); clear H2;
                etransitivity; [symmetry|]; eassumption);
        inversion F; subst; clear F
      end.
      match goal with
      | H: map.get e_impl fname = Some _, G: _ |- _ =>
          pose proof G as e_impl_reduced_props;
          specialize G with (1 := H);
          simpl in G
      end.
      simp.
      match goal with
      | H: map.get e_pos _ = Some _ |- _ => rename H into GetPos
      end.

      rename stack_trash into old_stackvals.

      set (FL := framelength (argnames, retnames, body)) in *.
      (* We have enough stack space for this call: *)
      assert (FL <= Z.of_nat (List.length old_stackvals)) as enough_stack_space. {
        match goal with
        | H: fits_stack _ _ _ |- _ => apply fits_stack_nonneg in H; clear -H
        end.
        unfold framelength in *. subst FL. simpl in *.
        blia.
      }

      assert (exists remaining_stack old_modvarvals old_ra old_retvals old_argvals,
                 old_stackvals = remaining_stack ++ old_modvarvals ++ [old_ra] ++
                                                 old_retvals ++ old_argvals /\
                 List.length old_modvarvals =
                    List.length (list_union Z.eqb (modVars_as_list Z.eqb body) argnames) /\
                 List.length old_retvals = List.length retnames /\
                 List.length old_argvals = List.length argnames) as TheSplit. {
        subst FL. unfold framelength in *.
        clear -enough_stack_space.
        rename old_stackvals into ToSplit.
        split_from_right ToSplit ToSplit old_argvals (List.length argnames).
        split_from_right ToSplit ToSplit old_retvals (List.length retnames).
        split_from_right ToSplit ToSplit old_ras 1%nat.
        split_from_right ToSplit ToSplit old_modvarvals
                (Datatypes.length (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)).
        destruct old_ras as [|old_ra rest]; try discriminate.
        destruct rest; try discriminate.
        repeat econstructor;
          [ do 3 rewrite <- List.app_assoc; reflexivity | blia.. ].
      }
      destruct TheSplit as (remaining_stack & old_modvarvals & old_ra & old_retvals & old_argvals
                                & ? & ? &  ? & ?).
      subst old_stackvals.

      (* note: left-to-right rewriting with all [length _ = length _] equations has to
         be terminating *)
      match goal with
      | H: _ |- _ => let N := fresh in pose proof H as N;
                     apply map.putmany_of_list_zip_sameLength in N;
                     symmetry in N
      end.
      match goal with
      | H: _ |- _ => let N := fresh in pose proof H as N;
                     apply map.getmany_of_list_length in N
      end.

      (* put arguments on stack *)
      eapply runsTo_trans. {
        eapply save_regs_correct with (vars := args) (p_sp0 := p_sp)
                (offset := (- bytes_per_word * Z.of_nat (List.length args))%Z); simpl; cycle -4.
        - eapply rearrange_footpr_subset; [ eassumption | wwcancel ].
        - wcancel_assumption.
        - sidecondition.
        - sidecondition.
        - sidecondition.
        - pose proof (NoDup_valid_FlatImp_vars_bound_length argnames) as A.
          auto_specialize.
          change (2 ^ 11) with 2048.
          assert (bytes_per_word = 4 \/ bytes_per_word = 8) as B. {
            clear. unfold bytes_per_word, Memory.bytes_per.
            destruct width_cases.
            + rewrite H. cbv. auto.
            + rewrite H. cbv. auto.
          }
          replace (Datatypes.length argnames) with (Datatypes.length args) in A;
            unfold Register, MachineInt in *; blia.
        - eapply map.getmany_of_list_extends; eassumption.
        - sidecondition.
        - unfold Register, MachineInt in *. blia.
      }

    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    assert (valid_register RegisterNames.ra) by (cbv; auto).
    assert (valid_register RegisterNames.sp) by (cbv; auto).

    (* jump to function *)
    eapply runsToStep. {
      eapply run_Jal; simpl; try solve [sidecondition]; cycle 2.
      - eapply rearrange_footpr_subset; [eassumption|wwcancel].
      - wcancel_assumption.
      - solve_divisibleBy4.
      - assumption.
    }

    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    pose proof functions_expose as P.
    match goal with
    | H: map.get e_impl _ = Some _ |- _ => specialize P with (2 := H)
    end.
    specialize P with (1 := GetPos).
    specialize (P program_base).
    match goal with
    | H: (_ * _)%sep _ |- _ => seprewrite_in P H
    end.
    apply iff1ToEq in P.
    match goal with
    | H: subset _ _ |- _ => rewrite P in H
    end.
    clear P.

    simpl in *.

    (* decrease sp *)
    eapply runsToStep. {
      eapply run_Addi with (rd := RegisterNames.sp) (rs := RegisterNames.sp);
        try solve [safe_sidecond | simpl; solve_divisibleBy4 ].
      simpl.
      rewrite map.get_put_diff by (clear; cbv; congruence).
      eassumption.
    }

    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* save ra on stack *)
    eapply runsToStep. {
      eapply run_store_word with (rs1 := RegisterNames.sp) (rs2 := RegisterNames.ra);
        try solve [sidecondition | simpl; solve_divisibleBy4].
        all: simpl.
      2: {
        eapply rearrange_footpr_subset; [ eassumption | wwcancel ].
      }
      1: {
        simpl.
        rewrite map.get_put_diff by (clear; cbv; congruence).
        rewrite map.get_put_same. reflexivity.
      }
      wcancel_assumption.
    }

    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* save vars modified by callee onto stack *)
    match goal with
    | |- context [ {| getRegs := ?l |} ] =>
      pose proof (@map.getmany_of_list_exists _ _ _ l valid_register (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)) as P
    end.
    edestruct P as [newvalues P2]; clear P.
    { eapply Forall_impl; cycle 1.
      - eapply union_Forall.
        * eapply modVars_as_list_valid_FlatImp_var. assumption.
        * assumption.
      - apply valid_FlatImp_var_implies_valid_register. }
    {
      intros.
      rewrite !map.get_put_dec.
      destruct_one_match; [eexists; reflexivity|].
      destruct_one_match; [eexists; reflexivity|].
      eauto.
    }
    eapply runsTo_trans. {
      eapply save_regs_correct; simpl; cycle 2.
      2: rewrite map.get_put_same; reflexivity.
      1: exact P2.
      2: { eapply rearrange_footpr_subset; [ eassumption | wwcancel ]. }
      4: assumption.
      4: {
        eapply Forall_impl; cycle 1.
        - eapply union_Forall.
          * eapply modVars_as_list_valid_FlatImp_var. assumption.
          * assumption.
        - apply valid_FlatImp_var_implies_valid_register. }
      1: eassumption.
      2: reflexivity.
      1: wcancel_assumption.
      pose proof (NoDup_valid_FlatImp_vars_bound_length (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)) as A.
      specialize_hyp A.
      - eapply list_union_preserves_NoDup. assumption.
      - apply union_Forall.
        * apply modVars_as_list_valid_FlatImp_var. assumption.
        * assumption.
      - change (2 ^ 11) with 2048.
        assert (bytes_per_word = 4 \/ bytes_per_word = 8) as B. {
          clear. unfold bytes_per_word, Memory.bytes_per.
          destruct width_cases.
          + rewrite H. cbv. auto.
          + rewrite H. cbv. auto.
        }
        clear -A B. unfold Register, MachineInt in *. blia.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* load argvars from stack *)
    eapply runsTo_trans. {
      eapply load_regs_correct with
          (vars := argnames) (values := argvs);
        simpl; cycle 2.
      - rewrite map.get_put_same. reflexivity.
      - assumption.
      - eapply rearrange_footpr_subset; [eassumption|wwcancel].
      - wcancel_assumption.
      - reflexivity.
      - assumption.
      - assumption.
      - pose proof (NoDup_valid_FlatImp_vars_bound_length retnames) as A.
        pose proof (NoDup_valid_FlatImp_vars_bound_length argnames) as A'.
        auto_specialize.
        change (2 ^ 11) with 2048.
        assert (bytes_per_word = 4 \/ bytes_per_word = 8) as B. {
          clear. unfold bytes_per_word, Memory.bytes_per.
          destruct width_cases.
          + rewrite H. cbv. auto.
          + rewrite H. cbv. auto.
        }
        pose proof (NoDup_valid_FlatImp_vars_bound_length (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)) as A''.
        specialize_hyp A''.
        + apply list_union_preserves_NoDup. assumption.
        + apply union_Forall.
          * apply modVars_as_list_valid_FlatImp_var. assumption.
          * assumption.
        + clear -A A' A'' B.
          change BinIntDef.Z.eqb with Z.eqb.
          unfold Register, MachineInt in *.
          match type of A'' with
          | (?x <= _)%nat => forget x as L
          end.
          destruct B as [B | B]; rewrite B; (* <-- TODO once we're on 8.10 delete this line *)
            blia.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* execute function body *)
    eapply runsTo_trans. {
      unfold good_reduced_e_impl, good_e_impl, valid_FlatImp_fun in *. simp.
      eapply IHexec with (g := {|
        p_sp := word.sub p_sp !(bytes_per_word * FL);
        e_pos := e_pos;
        program_base := program_base; |});
      after_IH;
      subst FL.
      all: try safe_sidecond.
      all: try safe_sidecond.
      { eapply map_extends_remove; eassumption. }
      { move e_impl_reduced_props at bottom.
        intros *. intro G.
        assert (map.get e_impl f = Some fun_impl) as G'. {
          eapply map_get_Some_remove; eassumption.
        }
        specialize e_impl_reduced_props with (1 := G'). simp.
        repeat split; eauto.
      }
      { eapply map.putmany_of_list_zip_extends; [eassumption..|].
        clear -h. unfold map.extends. intros. rewrite map.get_empty in H. discriminate H. }
      { match goal with
        | H: map.putmany_of_list_zip _ _ map.empty = Some st0,
          V: Forall valid_FlatImp_var argnames |- _ =>
          rename H into P; rename V into N; clear -P N h
        end.
        intros.
        pose proof (map.putmany_of_list_zip_find_index _ _ _ _ _ _ P H) as Q.
        destruct Q as [ [ n [A B] ] | C ].
        - eapply Forall_forall. 1: exact N.
          eapply nth_error_In. eassumption.
        - rewrite map.get_empty in C. discriminate.
      }
      {
        assert (forall x, In x argnames -> valid_FlatImp_var x) as F. {
          eapply Forall_forall.
          assumption.
        }
        revert F.
        repeat match goal with
               | H: ?T |- _ => lazymatch T with
                               | map.putmany_of_list_zip _ _ _ = Some middle_regs0 => revert H
                               | assumptions => fail
                               | _ => clear H
                               end
               end.
        intros PM F.

        eapply map.putmany_of_list_zip_get_oldval. 1: exact PM.
        - intro C. specialize (F _ C).
          unfold valid_FlatImp_var, RegisterNames.sp in F. blia.
        - rewrite map.get_put_same. f_equal. simpl_addrs. solve_word_eq word_ok.
      }
      {
        eapply preserve_regs_initialized_after_putmany_of_list_zip; cycle 1; try eassumption.
        eapply preserve_regs_initialized_after_put.
        eapply preserve_regs_initialized_after_put.
        assumption.
      }
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    match goal with
    | H: outcome _ _ _ _ |- _ => rename H into HO
    end.
    match goal with
    | H: forall _, _ |- _ =>
      specialize H with (1 := HO);
      move H at bottom;
      destruct H as (retvs & finalRegsH' & ? & ? & ?)
    end.

    (* save results onto stack *)
    eapply runsTo_trans. {
      eapply save_regs_correct with (vars := retnames); simpl; cycle 2.
      - eapply map.getmany_of_list_extends; try eassumption.
      - eassumption.
      - instantiate (1 := old_retvals). unfold Register, MachineInt in *. blia.
      - eapply rearrange_footpr_subset; [ eassumption | wwcancel ].
      - subst FL. wcancel_assumption.
      - reflexivity.
      - assumption.
      - eapply Forall_impl; cycle 1.
        + eassumption.
        + apply valid_FlatImp_var_implies_valid_register.
      - pose proof (NoDup_valid_FlatImp_vars_bound_length retnames) as A.
        auto_specialize.
        change (2 ^ 11) with 2048.
        assert (bytes_per_word = 4 \/ bytes_per_word = 8) as B. {
          clear. unfold bytes_per_word, Memory.bytes_per.
          destruct width_cases.
          + rewrite H. cbv. auto.
          + rewrite H. cbv. auto.
        }
        pose proof (NoDup_valid_FlatImp_vars_bound_length (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)) as A''.
        specialize_hyp A''.
        + apply list_union_preserves_NoDup. assumption.
        + apply union_Forall.
          * apply modVars_as_list_valid_FlatImp_var. assumption.
          * assumption.
        + clear -A A'' B.
          change BinIntDef.Z.eqb with Z.eqb.
          unfold Register, MachineInt in *.
          match type of A'' with
          | (?x <= _)%nat => forget x as L
          end.
          destruct B as [B | B]; rewrite B; (* <-- TODO once we're on 8.10 delete this line *)
            blia.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* load back the modified vars *)
    eapply runsTo_trans. {
      eapply load_regs_correct with
          (vars := (list_union Z.eqb (modVars_as_list _ body) argnames)) (values := newvalues);
        simpl; cycle 2.
      - eassumption.
      - repeat match goal with
               | H: map.getmany_of_list _ _ = Some _ |- _ =>
                 unique eapply @map.getmany_of_list_length in copy of H
               end.
        instantiate (1 := Z.eqb).
        unfold Register, MachineInt in *.
        blia.
      - eapply rearrange_footpr_subset; [eassumption|wwcancel].
      - subst FL. wcancel_assumption.
      - reflexivity.
      - assumption.
      - apply union_Forall.
        + apply modVars_as_list_valid_FlatImp_var. assumption.
        + assumption.
      - pose proof (NoDup_valid_FlatImp_vars_bound_length (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)) as A.
        specialize_hyp A.
        + apply list_union_preserves_NoDup. assumption.
        + apply union_Forall.
          * apply modVars_as_list_valid_FlatImp_var. assumption.
          * assumption.
        + change (2 ^ 11) with 2048.
          assert (bytes_per_word = 4 \/ bytes_per_word = 8) as B. {
            clear. unfold bytes_per_word, Memory.bytes_per.
            destruct width_cases.
            - rewrite H. cbv. auto.
            - rewrite H. cbv. auto.
          }
          clear -A B.
          destruct B as [B | B]; rewrite B; (* <-- TODO once we're on 8.10 delete this line *)
            blia.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog getMachine getMetrics].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* load back the return address *)
    eapply runsToStep. {
      eapply run_load_word; cycle 2.
      - simpl. solve [sidecondition].
      - simpl.
        assert (forall x, In x (list_union Z.eqb (modVars_as_list Z.eqb body) argnames) -> valid_FlatImp_var x) as F. {
          eapply Forall_forall.
          apply union_Forall.
          - apply modVars_as_list_valid_FlatImp_var. assumption.
          - assumption.
        }
        revert F.
        subst FL.
        repeat match goal with
               | H: ?T |- _ => lazymatch T with
                               | assumptions => fail
                               | map.putmany_of_list_zip _ _ _ = Some middle_regs2 => revert H
                               | map.get middle_regs1 RegisterNames.sp = Some _ => revert H
                               | _ => clear H
                               end
               end.
        intros G PM F.
        eapply map.putmany_of_list_zip_get_oldval. 3: exact G. 1: exact PM.
        intro C. specialize (F _ C).
        unfold valid_FlatImp_var, RegisterNames.sp in F. blia.
      - reflexivity.
      - simpl. eapply rearrange_footpr_subset; [ eassumption | wwcancel ].
      - simpl.
        subst FL. wcancel_assumption.
      - assumption.
      - assumption.
      - assumption.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* increase sp *)
    eapply runsToStep. {
     eapply (run_Addi RegisterNames.sp RegisterNames.sp); try safe_sidecond.
     - simpl.
        rewrite map.get_put_diff by (clear; cbv; congruence).
        repeat match goal with
               | H: ?T |- _ => lazymatch T with
                               | assumptions => fail
                               | map.putmany_of_list_zip _ _ _ = Some middle_regs2 => revert H
                               | map.get middle_regs1 RegisterNames.sp = Some _ => revert H
                               | valid_FlatImp_vars body => revert H
                               | Forall valid_FlatImp_var argnames => revert H
                               | _ => clear H
                               end
               end.
        intros F1 F2 G PM.
        eapply map.putmany_of_list_zip_get_oldval. 1: exact PM. 2: exact G.
        intro C.
        apply In_list_union_spec in C. destruct C.
        + apply_in_hyps modVars_as_list_valid_FlatImp_var.
          match goal with
          | H: Forall ?P ?L |- _ =>
            eapply (proj1 (Forall_forall P L)) in H; [rename H into B|eassumption]
          end.
          clear -B.
          unfold valid_FlatImp_var, RegisterNames.sp in *.
          blia.
        + match goal with
          | H: Forall ?P ?L |- _ =>
            eapply (proj1 (Forall_forall P L)) in H; [rename H into B|eassumption]
          end.
          clear -B.
          unfold valid_FlatImp_var, RegisterNames.sp in *.
          blia.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* jump back to caller *)
    eapply runsToStep. {
      eapply run_Jalr0 with (rs1 := RegisterNames.ra); simpl; try safe_sidecond.
      3: {
        rewrite map.get_put_diff by (clear; cbv; congruence).
        rewrite map.get_put_same. reflexivity.
      }
      1: reflexivity.
      1: solve_divisibleBy4.
      (* TODO: safe_sidecond should also solve these, even though it needs shrink_footpr_subset *)
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog getMachine].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* load result values from stack *)
    eapply runsTo_trans. {
      eapply load_regs_correct with
          (vars := binds) (values := retvs)
          (offset := (- bytes_per_word * Z.of_nat (List.length args + List.length binds))%Z)
          (p_sp0 := p_sp);
        simpl; cycle -4; try assumption.
      - safe_sidecond.
      - wcancel_assumption.
        subst FL.
        replace (Datatypes.length binds) with (Datatypes.length retnames); cycle 1. {
            repeat match goal with
            | H: _ |- _ => let N := fresh in pose proof H as N;
                                               apply map.putmany_of_list_zip_sameLength in N;
                                               symmetry in N;
                                               ensure_new N
            end.
            repeat match goal with
            | H: _ |- _ => let N := fresh in pose proof H as N;
                                               apply map.getmany_of_list_length in N;
                                               ensure_new N
            end.
            simpl_addrs.
            reflexivity.
        }
        simpl_addrs.
        cbn [seps].
        wcancel.
      - reflexivity.
      - pose proof (NoDup_valid_FlatImp_vars_bound_length argnames) as A.
        pose proof (NoDup_valid_FlatImp_vars_bound_length retnames) as A'.
        auto_specialize.
        change (2 ^ 11) with 2048.
        assert (bytes_per_word = 4 \/ bytes_per_word = 8) as B. {
          clear. unfold bytes_per_word, Memory.bytes_per.
          destruct width_cases.
          + rewrite H. cbv. auto.
          + rewrite H. cbv. auto.
        }
        unfold Register, MachineInt in *.
        replace (Datatypes.length argnames) with (Datatypes.length args) in A by blia.
        match goal with
        | H: map.getmany_of_list _ retnames = Some _ |- _ =>
          rename H into G; move G at bottom
        end.
        apply map.getmany_of_list_length in G.
        match goal with
        | H: map.putmany_of_list_zip _ retvs _ = Some _ |- _ =>
          rename H into G'; move G' at bottom
        end.
        apply map.putmany_of_list_zip_sameLength in G'.
        replace (Datatypes.length retnames) with (Datatypes.length binds) in A' by blia.
        clear -A A' B.
        destruct B as [B | B]; rewrite B; (* <-- TODO once we're on 8.10 delete this line *)
          blia.
      - subst FL.
        simpl_addrs.
        rewrite map.get_put_same. f_equal. solve_word_eq word_ok.
      - repeat match goal with
               | H: _ |- _ => let N := fresh in pose proof H as N;
                                                  apply map.putmany_of_list_zip_sameLength in N;
                                                  symmetry in N;
                                                  ensure_new N
               end.
        repeat match goal with
               | H: _ |- _ => let N := fresh in pose proof H as N;
                                                  apply map.getmany_of_list_length in N;
                                                  ensure_new N
               end.
        simpl_addrs.
        reflexivity.
    }

    simpl.
    cbn [getRegs getPc getNextPc getMem getLog getMachine].
    clear_old_sep_hyps.
    intros. simp.
    repeat match goal with
           | m: _ |- _ => destruct_RiscvMachine m
           end.
    subst.

    (* computed postcondition satisfies required postcondition: *)
    apply runsToDone.
    cbn [getRegs getPc getNextPc getMem getLog getMachine].
    do 4 eexists.
    ssplit.
    + eassumption.
    + simpl_addrs. rewrite length_load_regs. rewrite length_save_regs. simpl_addrs.
      solve_word_eq word_ok.
    + apply_in_hyps (@map.only_differ_putmany _ _ _ locals_ok _ _).
      (* TODO these should be in map_solver or another automated step *)
      rewrite ?of_list_list_union in *.
      change (of_list []) with (@empty_set Register).
      (* TODO map_solver should be fast enough without this manual clearing *)
      repeat match goal with
             | H: (_ * _)%sep _ |- _ => clear H
             | H: valid_machine _ |- _ => clear H
             end.
      clear IHexec.
      (* TODO map_solver should work here, but it's too slow *)

      unfold map.only_differ.
      intros x.
      unfold PropSet.union, PropSet.elem_of, of_list.
      destruct (in_dec Z.eq_dec x binds) as [HI | HNI].
      1: clear -HI; auto.
      destr (Z.eqb x RegisterNames.ra). {
        subst. unfold singleton_set. auto.
      }
      right.
      lazymatch goal with
      | H: map.putmany_of_list_zip ?S _ middle_regs1 = Some middle_regs2 |- _ =>
        destruct (in_dec Z.eq_dec x S) as [HI' | HNI']
      end.
      * (* 1) prove that LHS is in newvalues: *)
        pose proof (In_nth_error _ _ HI') as B. destruct B as [i B].
        pose proof @map.getmany_of_list_get as D. specialize D with (1 := P2) (2 := B).
        pose proof (nth_error_Some (list_union Z.eqb (modVars_as_list Z.eqb body) argnames) i)
          as N. apply proj1 in N. specialize_hyp N. 1: congruence.
        lazymatch goal with
        | H: map.putmany_of_list_zip ?S _ middle_regs1 = Some middle_regs2 |- _ =>
          pose proof (map.putmany_of_list_zip_sameLength _ _ _ _ H) as Q
        end.
        unfold Register, MachineInt in *. rewrite Q in N.
        apply nth_error_Some in N.
        destr (nth_error newvalues i); try congruence.
        specialize D with (1 := eq_refl).
        rewrite map.get_put_diff in D.
        2: {
          move HI' at bottom.
          intro C. subst.
          apply In_list_union_spec in HI'. destruct HI' as [HI' | HI'].
          + apply_in_hyps modVars_as_list_valid_FlatImp_var.
            match goal with
            | H: Forall ?P ?L |- _ =>
              eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
            end.
            clear -BB.
            unfold valid_FlatImp_var, RegisterNames.sp in *.
            blia.
          + match goal with
            | H: Forall ?P ?L |- _ =>
              eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
            end.
            clear -BB.
            unfold valid_FlatImp_var, RegisterNames.sp in *.
            blia.
        }
        rewrite map.get_put_diff in D.
        2: {
          move HI' at bottom.
          intro C. subst.
          apply In_list_union_spec in HI'. destruct HI' as [HI' | HI'].
          + apply_in_hyps modVars_as_list_valid_FlatImp_var.
            match goal with
            | H: Forall ?P ?L |- _ =>
              eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
            end.
            clear -BB.
            unfold valid_FlatImp_var, RegisterNames.ra in *.
            blia.
          + match goal with
            | H: Forall ?P ?L |- _ =>
              eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
            end.
            clear -BB.
            unfold valid_FlatImp_var, RegisterNames.ra in *.
            blia.
        }
        rewrite D. rewrite <- E0.

        (* 2) prove that RHS is in newvalues: *)
        replace (map.get middle_regs3 x) with (map.get middle_regs2 x); cycle 1. {
          symmetry.
          eapply only_differ_get_unchanged; cycle 1.
          - eassumption.
          - exact HNI.
          - rewrite map.get_put_diff.
            2: {
              move HI' at bottom.
              intro C. subst.
              apply In_list_union_spec in HI'. destruct HI' as [HI' | HI'].
              + apply_in_hyps modVars_as_list_valid_FlatImp_var.
                match goal with
                | H: Forall ?P ?L |- _ =>
                  eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
                end.
                clear -BB.
                unfold valid_FlatImp_var, RegisterNames.sp in *.
                blia.
              + match goal with
                | H: Forall ?P ?L |- _ =>
                  eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
                end.
                clear -BB.
                unfold valid_FlatImp_var, RegisterNames.sp in *.
                blia.
            }
            rewrite map.get_put_diff.
            2: {
              move HI' at bottom.
              intro C. subst.
              apply In_list_union_spec in HI'. destruct HI' as [HI' | HI'].
              + apply_in_hyps modVars_as_list_valid_FlatImp_var.
                match goal with
                | H: Forall ?P ?L |- _ =>
                  eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
                end.
                clear -BB.
                unfold valid_FlatImp_var, RegisterNames.ra in *.
                blia.
              + match goal with
                | H: Forall ?P ?L |- _ =>
                  eapply (proj1 (Forall_forall P L)) in H; [rename H into BB|eassumption]
                end.
                clear -BB.
                unfold valid_FlatImp_var, RegisterNames.ra in *.
                blia.
            }
            reflexivity.
        }

        pose proof (map.putmany_of_list_zip_get_newval (ok := locals_ok)) as D'.
        lazymatch goal with
        | H: map.putmany_of_list_zip _ _ middle_regs1 = Some middle_regs2 |- _ =>
          specialize D' with (1 := H) (3 := B) (4 := E0)
        end.
        unfold Register, MachineInt in *.
        rewrite D'; cycle 1. {
          eapply list_union_preserves_NoDup. assumption.
        }
        assumption.
      * (* if not in modvars (HNI'): *)
        destr (Z.eqb x RegisterNames.sp).
        { subst.
          transitivity (Some p_sp). 1: assumption.
          symmetry.
          eapply map.putmany_of_list_zip_get_oldval; try eassumption.
          rewrite map.get_put_same.
          f_equal.
          subst FL.
          unfold Register, MachineInt.
          solve_word_eq word_ok. }
        {
          (* _ to 0 *)
          lazymatch goal with
          | H: map.only_differ _ _ middle_regs0 |- _ => rename H into A; move A at bottom
          end.
          unfold map.only_differ in A. specialize (A x).
          destruct A as [A | A]. {
            unfold elem_of, of_list in A.
            exfalso. apply HNI'.
            apply In_list_union_spec. right. exact A.
          }
          do 2 rewrite map.get_put_diff in A by assumption.
          unfold Register, MachineInt in *.
          rewrite A. clear A.
          (* 0 to 1 *)
          lazymatch goal with
          | H: map.only_differ _ _ middle_regs1 |- _ => rename H into A; move A at bottom
          end.
          unfold map.only_differ in A. specialize (A x).
          destruct A as [A | A]. {
            unfold union, elem_of, of_list, singleton_set in A.
            exfalso.
            destruct A as [A | A].
            - apply HNI'.
              apply In_list_union_spec. left. exact A.
            - congruence.
          }
          rewrite A. clear A.
          (* 1 to 2 *)
          lazymatch goal with
          | H: map.only_differ _ _ middle_regs2 |- _ => rename H into A; move A at bottom
          end.
          unfold map.only_differ in A. specialize (A x).
          destruct A as [A | A]. {
            unfold elem_of, union in A.
            destruct A as [A | A].
            - unfold elem_of, of_list in A.
              exfalso. apply HNI'.
              apply In_list_union_spec. auto.
            - exfalso. apply HNI'.
              apply In_list_union_spec. auto.
          }
          rewrite A. clear A.
          (* 2 to 3 *)
          lazymatch goal with
          | H: map.only_differ _ _ middle_regs3 |- _ => rename H into A; move A at bottom
          end.
          unfold map.only_differ in A. specialize (A x).
          destruct A as [A | A]. {
            unfold elem_of, of_list in A.
            exfalso. apply HNI. exact A.
          }
          do 2 rewrite map.get_put_diff in A by assumption.
          rewrite A. reflexivity.
        }

    + rename l into lH, finalRegsH into lFH', finalRegsH' into lH', st0 into lFH,
             middle_regs into lL.

      (* The following list of lemmas and about that much helper code would probably be required
         even in a near-perfect proof assistant:

         Summary of what happened in FlatImp:

         Action (in order):
         ------------------------------
         put (argnames, argvals) from outer locals into new empty map
         execute function body
         take (retnames, retvals) out of map and put into outer locals



         Summary of what happened in riscv:              Original low-level locals: lL

         Action (in order):               Correctness lemma:      New low-level locals:
         -------------------------------  ---------------------   ---------------------
         put arguments on stack           save_regs_correct
         jump to function                 run_Jal
         decrease sp                      run_Addi
         save ra on stack                 run_store_word
         save vars modified by callee     save_regs_correct
         load argvars from stack          load_regs_correct       middle_regs0
         execute function body            IHexec                  middle_regs1
         save results onto stack          save_regs_correct
         load back the modified vars      load_regs_correct       middle_regs2
         load back the return address     run_load_word
         increase sp                      run_Addi
         jump back to caller              run_Jalr0
         load result values from stack    load_regs_correct       middle_regs3
       *)

      lazymatch goal with
      | H: map.putmany_of_list_zip _ _ _ = Some middle_regs3 |- _ =>
        rename H into P; move P at bottom
      end.
      apply map.putmany_of_list_zip_to_putmany in P.
      destruct P as [lBR [P ?]].
      match goal with
      | H: map.putmany_of_list_zip _ _ lH = Some lH' |- _ =>
        move H at bottom; rename H into Q
      end.
      apply map.putmany_of_list_zip_to_putmany in Q.
      destruct Q as [lBR' [Q ?]].
      unfold Register, MachineInt in *.
      rewrite P in Q. replace lBR' with lBR in * by congruence.
      subst.
      unfold map.extends.
      intros x v G.
      rewrite map.get_putmany_dec in G |- *.
      destr (map.get lBR x). 1: congruence.
      assert (valid_FlatImp_var x) as V by eauto.
      rewrite map.get_put_diff; cycle 1. {
        clear -V. unfold valid_FlatImp_var, RegisterNames.sp in *. blia.
      }
      rewrite map.get_put_diff; cycle 1. {
        clear -V. unfold valid_FlatImp_var, RegisterNames.ra in *. blia.
      }
      lazymatch goal with
      | H: map.putmany_of_list_zip _ _ _ = Some middle_regs2 |- _ =>
        rename H into P'; move P' at bottom
      end.
      apply map.putmany_of_list_zip_to_putmany in P'.
      destruct P' as [lM [P' ?]].
      subst.
      rewrite map.get_putmany_dec.
      destr (map.get lM x). {
        move P2 at bottom.
        pose proof @map.getmany_of_list_get as D. specialize D with (1 := P2).
        pose proof (map.putmany_of_list_zip_find_index _ _ _ _ _ _ P' E0) as F.
        destruct F as [ [ n [F1 F2] ] | F ]; cycle 1. {
          rewrite map.get_empty in F. discriminate.
        }
        specialize D with (1 := F1) (2 := F2).
        rewrite map.get_put_diff in D; cycle 1. {
          clear -V. unfold valid_FlatImp_var, RegisterNames.sp in *. blia.
        }
        rewrite map.get_put_diff in D; cycle 1. {
          clear -V. unfold valid_FlatImp_var, RegisterNames.ra in *. blia.
        }
        match goal with
        | H: map.extends lL lH |- _ =>
          move H at bottom; rename H into Ex
        end.
        unfold map.extends in Ex. specialize Ex with (1 := G). congruence.
      }
      (* now E0 tells us that x is not in the callee-saved modvars*)
      lazymatch goal with
      | H: map.only_differ middle_regs0 _ middle_regs1 |- _ =>
        move H at bottom; rename H into OD
      end.
      unfold map.only_differ in OD. specialize (OD x).
      unfold union, of_list, singleton_set, elem_of in OD.
      destruct OD as [OD | OD]. {
        destruct OD as [OD | OD].
        - assert (In x (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)) as I2. {
            eapply In_list_union_spec. auto.
          }
          apply In_nth_error in I2. destruct I2 as [i I2].
          pose proof (map.putmany_of_list_zip_empty_find_value _ _ _ _ _ P' I2) as C.
          destruct C as [vi C].
          epose proof (map.putmany_of_list_zip_get_newval _ _ _ _ _ _ _ P' _ I2) as A.
          specialize (A C).
          clear -A E0. congruence.
        - subst x. clear -V. exfalso. unfold valid_FlatImp_var, RegisterNames.ra in *. blia.
      }
      rewrite <- OD.
      lazymatch goal with
      | H: map.putmany_of_list_zip _ _ _ = Some middle_regs0 |- _ =>
        rename H into P''; move P'' at bottom
      end.
      apply map.putmany_of_list_zip_to_putmany in P''.
      destruct P'' as [lA [P'' ?]].
      subst.
      rewrite map.get_putmany_dec in OD |- *.
      clear Q.
      destr (map.get lA x). {
        pose proof (map.putmany_of_list_zip_find_index _ _ _ _ _ _ P'' E1) as Q.
        destruct Q as [ [ n [A B] ] | C ]; cycle 1. {
          rewrite map.get_empty in C. discriminate.
        }
        assert (In x (list_union Z.eqb (modVars_as_list Z.eqb body) argnames)) as I2. {
          eapply In_list_union_spec.
          pose proof nth_error_In; eauto.
        }
        apply In_nth_error in I2. destruct I2 as [i I2].
        pose proof (map.putmany_of_list_zip_empty_find_value _ _ _ _ _ P' I2) as C.
        destruct C as [vi C].
        epose proof (map.putmany_of_list_zip_get_newval _ _ _ _ _ _ _ P' _ I2) as F.
        specialize (F C).
        clear -F E0. congruence.
      }
      rewrite map.get_put_diff; cycle 1. {
        clear -V. unfold valid_FlatImp_var, RegisterNames.sp in *. blia.
      }
      rewrite map.get_put_diff; cycle 1. {
        clear -V. unfold valid_FlatImp_var, RegisterNames.ra in *. blia.
      }
      match goal with
      | H: map.extends lL lH |- _ => clear -H G h
      end.
      map_solver locals_ok.

    + match goal with
      | H: map.putmany_of_list_zip _ _ _ = Some finalRegsH' |- _ =>
        move H at bottom; rename H into P
      end.
      intros x v G.
      pose proof (map.putmany_of_list_zip_find_index _ _ _ _ _ _ P G) as Q.
      destruct Q as [ [ n [A B] ] | C ].
      * eapply Forall_forall; cycle 1.
        { eapply nth_error_In. eassumption. }
        { assumption. }
      * eauto.
    + subst FL.
      assert (Forall valid_FlatImp_var binds) as A. {
        assumption.
      }
      match goal with
      | H: map.putmany_of_list_zip _ _  (map.put (map.put _ _ _) _ ?v) = Some ?m2 |-
        map.get ?m2 _ = Some ?v' =>
        rename H into D; clear -D h A;
        replace v with v' in D by (unfold Register, MachineInt; solve_word_eq word_ok)
      end.
      eapply map.putmany_of_list_zip_get_oldval.
      * exact D.
      * intro C.
        eapply Forall_forall in A. 2: exact C.
        cbv in A. intuition congruence.
      * rewrite map.get_put_same. reflexivity.
    + eapply preserve_regs_initialized_after_putmany_of_list_zip; cycle 1; try eassumption.
      eapply preserve_regs_initialized_after_put.
      eapply preserve_regs_initialized_after_put.
      eapply preserve_regs_initialized_after_putmany_of_list_zip; cycle 1; try eassumption.
    + reflexivity.
    + simpl.
      eapply rearrange_footpr_subset; [ eassumption | ].
      pose proof functions_expose as P.
      match goal with
      | H: map.get e_impl _ = Some _ |- _ => specialize P with (2 := H)
      end.
      specialize P with (1 := GetPos).
      specialize (P program_base).
      apply iff1ToEq in P.
      rewrite P. clear P.
      simpl.
      wwcancel.
    + epose (?[new_ra]: word) as new_ra. cbv delta [id] in new_ra.
      match goal with
      | H:   #(Datatypes.length ?new_remaining_stack) = _ |- _ =>
        exists (new_remaining_stack ++ newvalues ++ [new_ra] ++ retvs ++ argvs)
      end.
      assert (Datatypes.length (list_union Z.eqb (modVars_as_list Z.eqb body) argnames) = Datatypes.length newvalues). {
        eapply map.getmany_of_list_length. eassumption.
      }
      assert (Datatypes.length retnames = Datatypes.length retvs). {
        eapply map.getmany_of_list_length. eassumption.
      }
      assert (Datatypes.length retvs = Datatypes.length binds). {
        symmetry. eapply map.putmany_of_list_zip_sameLength. eassumption.
      }
      (* PARAMRECORDS *)
      change Z with Register in *.
      subst FL new_ra. simpl_addrs.
      split. { ring. (* faster than lia *) }
      use_sep_assumption.
      wseplog_pre.
      pose proof functions_expose as P.
      match goal with
      | H: map.get e_impl _ = Some _ |- _ => specialize P with (2 := H)
      end.
      specialize P with (1 := GetPos).
      specialize (P program_base).
      apply iff1ToEq in P.
      rewrite P. clear P.
      unfold program, compile_function.
      rewr (fun t => match t with
           | context [ array ?PT ?SZ ?start (?xs ++ ?ys) ] =>
             constr:(iff1ToEq (array_append' PT SZ xs ys start))
           | context [ array ?PT ?SZ ?start (?x :: ?xs) ] =>
             constr:(iff1ToEq (array_cons PT SZ x xs start))
           end) in |-*.
      (* PARAMRECORDS *)
      repeat match goal with
             | |- context [@array ?Wi ?Wo ?V ?M ?T ?E ?SZ ?A nil] =>
               change (@array Wi Wo V M T E SZ A nil) with (emp True)
             end.
      rewrite! length_save_regs. rewrite! length_load_regs. (* <- needs to be before simpl_addrs *)
      simpl_addrs. simpl. (* PARAMRECORDS *)
      wcancel.
    + reflexivity.
    + assumption.

    - idtac "Case compile_stmt_correct/SLoad".
      progress unfold Memory.load, Memory.load_Z in *. simp.
      subst_load_bytes_for_eq.
      assert (x <> RegisterNames.sp). {
        unfold valid_FlatImp_var, RegisterNames.sp in *.
        blia.
      }
      run1det. clear H0. (* <-- TODO this should not be needed *) unfold Register, MachineInt in *. run1done.

    - idtac "Case compile_stmt_correct/SStore".
      simpl_MetricRiscvMachine_get_set.
      unfold Memory.store, Memory.store_Z in *.
      change Memory.store_bytes with Platform.Memory.store_bytes in *.
      match goal with
      | H: Platform.Memory.store_bytes _ _ _ _ = _ |- _ =>
        unshelve epose proof (@store_bytes_frame _ _ _ _ _ _ _ _ _ H _) as P; cycle 2
      end.
      1: ecancel_assumption.
      destruct P as (finalML & P1 & P2).
      match goal with
      | H: _ = Some m' |- _ => move H at bottom; rename H into A
      end.
      unfold Platform.Memory.store_bytes, Memory.store_Z, Memory.store_bytes in A. simp.
      subst_load_bytes_for_eq.
      run1det. run1done.
      eapply preserve_subset_of_xAddrs. 1: assumption.
      ecancel_assumption.

    - idtac "Case compile_stmt_correct/SLit".
      get_run1valid_for_free.
      eapply compile_lit_correct_full.
      + sidecondition.
      + safe_sidecond.
      + unfold compile_stmt. simpl. ecancel_assumption.
      + sidecondition.
      + assumption.
      + simpl.
        assert (x <> RegisterNames.sp). {
          unfold valid_FlatImp_var, RegisterNames.sp in *.
          blia.
        }
        unfold Register, MachineInt in *.
        run1done.

    - idtac "Case compile_stmt_correct/SOp".
      assert (x <> RegisterNames.sp). {
        unfold valid_FlatImp_var, RegisterNames.sp in *.
        blia.
      }
      match goal with
      | o: Syntax.bopname.bopname |- _ => destruct o
      end;
      simpl in *; run1det;
      rewrite ?word.sru_ignores_hibits,
              ?word.slu_ignores_hibits,
              ?word.srs_ignores_hibits,
              ?word.mulhuu_simpl,
              ?word.divu0_simpl,
              ?word.modu0_simpl in *.
      all: try solve [unfold Register, MachineInt in *; run1done].
      (* bopname.eq requires two instructions *)
      run1det. unfold Register, MachineInt in *. run1done.
      rewrite reduce_eq_to_sub_and_lt.
      rewrite map.put_put_same.
      map_solver locals_ok.

    - idtac "Case compile_stmt_correct/SSet".
      assert (x <> RegisterNames.sp). {
        unfold valid_FlatImp_var, RegisterNames.sp in *.
        blia.
      }
      run1det. unfold Register, MachineInt in *. run1done.

    - idtac "Case compile_stmt_correct/SIf/Then".
      (* execute branch instruction, which will not jump *)
      eapply runsTo_det_step_with_valid_machine; simpl in *; subst.
      + assumption.
      + simulate'. simpl_MetricRiscvMachine_get_set.
        destruct cond; [destruct op | ];
          simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity.
      + intro V. eapply runsTo_trans; simpl_MetricRiscvMachine_get_set.
        * (* use IH for then-branch *)
          eapply IHexec with (g := {| p_sp := _; |}) (pos := (pos + 4)%Z);
            after_IH;
            try safe_sidecond.
          all: try safe_sidecond.
          all: try safe_sidecond.
        * (* jump over else-branch *)
          simpl. intros. destruct_RiscvMachine middle. simp. subst.
          run1det. run1done.

    - idtac "Case compile_stmt_correct/SIf/Else".
      (* execute branch instruction, which will jump over then-branch *)
      eapply runsTo_det_step_with_valid_machine; simpl in *; subst.
      + assumption.
      + simulate'.
        destruct cond; [destruct op | ];
          simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity.
      + intro V. eapply runsTo_trans; simpl_MetricRiscvMachine_get_set.
        * (* use IH for else-branch *)
          eapply IHexec with (g := {| p_sp := _; |});
            after_IH;
            try safe_sidecond.
            all: try safe_sidecond.
        * (* at end of else-branch, i.e. also at end of if-then-else, just prove that
             computed post satisfies required post *)
          simpl. intros. destruct_RiscvMachine middle. simp. subst. run1done.

    - idtac "Case compile_stmt_correct/SLoop".
      on hyp[(stmt_not_too_big body1); runsTo] do (fun H => rename H into IH1).
      on hyp[(stmt_not_too_big body2); runsTo] do (fun H => rename H into IH2).
      on hyp[(stmt_not_too_big (SLoop body1 cond body2)); runsTo] do (fun H => rename H into IH12).
      eapply runsTo_trans; simpl_MetricRiscvMachine_get_set.
      + (* 1st application of IH: part 1 of loop body *)
          eapply IH1 with (g := {| p_sp := _; |});
            after_IH;
            try safe_sidecond.
          all: try safe_sidecond.
      + simpl in *. simpl. intros. destruct_RiscvMachine middle.
        match goal with
        | H: exists _ _ _ _, _ |- _ => destruct H as [ tH' [ mH' [ lH' [ mcH' H ] ] ] ]
        end.
        simp. subst.
        destruct (@eval_bcond Z (@Semantics_params p) lH' cond) as [condB|] eqn: E.
        2: exfalso;
           match goal with
           | H: context [_ <> None] |- _ => solve [eapply H; eauto]
           end.
        destruct condB.
        * (* true: iterate again *)
          eapply runsTo_det_step_with_valid_machine; simpl in *; subst.
          { assumption. }
          { simulate'.
            destruct cond; [destruct op | ];
              simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity. }
          { intro V. eapply runsTo_trans; simpl_MetricRiscvMachine_get_set.
            - (* 2nd application of IH: part 2 of loop body *)
              eapply IH2 with (g := {| p_sp := _; |});
                after_IH;
                try safe_sidecond.
              all: try safe_sidecond.
              1: eassumption.
              all: try safe_sidecond.
              all: try safe_sidecond.
            - simpl in *. simpl. intros. destruct_RiscvMachine middle. simp. subst.
              (* jump back to beginning of loop: *)
              run1det.
              eapply runsTo_trans; simpl_MetricRiscvMachine_get_set.
              + (* 3rd application of IH: run the whole loop again *)
                eapply IH12 with (g := {| p_sp := _; |});
                  after_IH.
                all: try safe_sidecond.
                1: eassumption.
                all: try safe_sidecond.
                1: constructor; congruence.
                all: try safe_sidecond.
              + (* at end of loop, just prove that computed post satisfies required post *)
                simpl. intros. destruct_RiscvMachine middle. simp. subst.
                run1done. }
        * (* false: done, jump over body2 *)
          eapply runsTo_det_step_with_valid_machine; simpl in *; subst.
          { assumption. }
          { simulate'.
            destruct cond; [destruct op | ];
              simpl in *; simp; repeat (simulate'; simpl_bools; simpl); try reflexivity. }
          { intro V. simpl in *. run1done. }

    - idtac "Case compile_stmt_correct/SSeq".
      on hyp[(stmt_not_too_big s1); runsTo] do (fun H => rename H into IH1).
      on hyp[(stmt_not_too_big s2); runsTo] do (fun H => rename H into IH2).
      eapply runsTo_trans.
      + eapply IH1 with (g := {| p_sp := _; |});
          after_IH;
          try safe_sidecond.
        all: try safe_sidecond.
      + simpl. intros. destruct_RiscvMachine middle. simp. subst.
        eapply runsTo_trans.
        * eapply IH2 with (g := {| p_sp := _; |});
            after_IH;
            try safe_sidecond.
          1: eassumption.
          all: try safe_sidecond.
          all: try safe_sidecond.
        * simpl. intros. destruct_RiscvMachine middle. simp. subst. run1done.

    - idtac "Case compile_stmt_correct/SSkip".
      run1done.

    Grab Existential Variables.
    all: try (apply list_union_preserves_NoDup; assumption).
    all: try (unfold env; simpl; eapply funname_env_ok).
    all: repeat (exact Z0 || assumption || constructor).
  Qed. (* <-- takes a while *)

End Proofs.

Ltac omega_safe ::= idtac.
