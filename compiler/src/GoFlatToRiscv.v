Require Import Coq.ZArith.BinInt.
Require Import Coq.micromega.Lia.
Require Import Coq.omega.Omega.
Require Import Coq.Lists.List. Import ListNotations.
Require Import coqutil.Map.Interface coqutil.Map.Properties.
Require Import coqutil.Word.Interface coqutil.Word.Properties.
Require Import riscv.Utility.Monads.
Require Import riscv.Utility.Utility.
Require Import riscv.Spec.Decode.
Require Import riscv.Platform.Memory.
Require Import riscv.Spec.Machine.
Require Import riscv.Platform.RiscvMachine.
Require Import riscv.Spec.Primitives.
Require Import riscv.Platform.Run.
Require Import riscv.Spec.Execute.
Require Import riscv.Proofs.DecodeEncode.
Require Import coqutil.Tactics.Tactics.
Require Import compiler.util.Tactics.
Require Import compiler.SeparationLogic.
Require Import compiler.EmitsValid.
Require Import bedrock2.ptsto_bytes.
Require Import bedrock2.Scalars.
Require Import riscv.Utility.Encode.
Require Import riscv.Proofs.EncodeBound.


Section Go.

  Context {W: Words}.
  Context {Registers: map.map Register word}.
  Context {Action: Type}.
  Context {mem: map.map word byte}.
  Context {mem_ok: map.ok mem}.

  Local Notation RiscvMachineL := (RiscvMachine Register Action).

  Context {M: Type -> Type}.
  Context {MM: Monad M}.
  Context {RVM: RiscvProgram M word}.
  Context {PRParams: PrimitivesParams M (RiscvMachine Register Action)}.
  Context {PR: Primitives PRParams}.
  Variable iset: InstructionSet.

  Lemma spec_Bind_det{A B: Type}: forall (initialL: RiscvMachineL)
       (post: B -> RiscvMachineL -> Prop) (m: M A) (f : A -> M B) (a: A) (mid: RiscvMachineL),
      mcomp_sat m initialL (fun a' mid' => a' = a /\ mid' = mid) ->
      mcomp_sat (f a) mid post ->
      mcomp_sat (Bind m f) initialL post.
  Proof.
    intros. eapply spec_Bind. eexists. split; [exact H|]. intros. simpl in *.
    destruct H1. subst. assumption.
  Qed.

  (* redefine mcomp_sat to simplify for the case where no answer is returned *)
  Definition mcomp_sat(m: M unit)(initialL: RiscvMachineL)(post: RiscvMachineL -> Prop): Prop :=
    mcomp_sat m initialL (fun (_: unit) => post).

  Ltac t lem :=
    intros;
    try (eapply spec_Bind_det; [|eassumption]); (* try because go_step doesn't need Bind *)
    apply lem;
    rewrite_match;
    eauto.

  Lemma go_getRegister: forall (initialL: RiscvMachineL) (x: Register) v post (f: word -> M unit),
      valid_register x ->
      map.get initialL.(getRegs) x = Some v ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (getRegister x) f) initialL post.
  Proof. t spec_getRegister. Qed.

  Lemma go_getRegister0: forall (initialL: RiscvMachineL) post (f: word -> M unit),
      mcomp_sat (f (ZToReg 0)) initialL post ->
      mcomp_sat (Bind (getRegister Register0) f) initialL post.
  Proof. t spec_getRegister. Qed.

  Lemma go_setRegister: forall initialL x v post (f: unit -> M unit),
      valid_register x ->
      mcomp_sat (f tt) (withRegs (map.put initialL.(getRegs) x v) initialL) post ->
      mcomp_sat (Bind (setRegister x v) f) initialL post.
  Proof. t spec_setRegister. Qed.

  Lemma go_setRegister0: forall initialL v post (f: unit -> M unit),
      mcomp_sat (f tt) initialL post ->
      mcomp_sat (Bind (setRegister Register0 v) f) initialL post.
  Proof. t spec_setRegister. Qed.

  Lemma go_loadByte: forall initialL kind addr (v: w8) (f: w8 -> M unit) post,
      Memory.loadByte initialL.(getMem) addr = Some v ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (Machine.loadByte kind addr) f) initialL post.
  Proof. t spec_loadByte. Qed.

  Lemma go_loadHalf: forall initialL kind addr (v: w16) (f: w16 -> M unit) post,
      Memory.loadHalf initialL.(getMem) addr = Some v ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (Machine.loadHalf kind addr) f) initialL post.
  Proof. t spec_loadHalf. Qed.

  Lemma go_loadWord: forall initialL kind addr (v: w32) (f: w32 -> M unit) post,
      Memory.loadWord initialL.(getMem) addr = Some v ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (Machine.loadWord kind addr) f) initialL post.
  Proof. t spec_loadWord. Qed.

  Lemma go_loadDouble: forall initialL kind addr (v: w64) (f: w64 -> M unit) post,
      Memory.loadDouble initialL.(getMem) addr = Some v ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (Machine.loadDouble kind addr) f) initialL post.
  Proof. t spec_loadDouble. Qed.

  Lemma go_storeByte: forall initialL kind addr v m' post (f: unit -> M unit),
        Memory.storeByte initialL.(getMem) addr v = Some m' ->
        mcomp_sat (f tt) (withMem m' initialL) post ->
        mcomp_sat (Bind (Machine.storeByte kind addr v) f) initialL post.
  Proof. t spec_storeByte. Qed.

  Lemma go_storeHalf: forall initialL kind addr v m' post (f: unit -> M unit),
        Memory.storeHalf initialL.(getMem) addr v = Some m' ->
        mcomp_sat (f tt) (withMem m' initialL) post ->
        mcomp_sat (Bind (Machine.storeHalf kind addr v) f) initialL post.
  Proof. t spec_storeHalf. Qed.

  Lemma go_storeWord: forall initialL kind addr v m' post (f: unit -> M unit),
        Memory.storeWord initialL.(getMem) addr v = Some m' ->
        mcomp_sat (f tt) (withMem m' initialL) post ->
        mcomp_sat (Bind (Machine.storeWord kind addr v) f) initialL post.
  Proof. t spec_storeWord. Qed.

  Lemma go_storeDouble: forall initialL kind addr v m' post (f: unit -> M unit),
        Memory.storeDouble initialL.(getMem) addr v = Some m' ->
        mcomp_sat (f tt) (withMem m' initialL) post ->
        mcomp_sat (Bind (Machine.storeDouble kind addr v) f) initialL post.
  Proof. t spec_storeDouble. Qed.

  Lemma go_getPC: forall initialL (f: word -> M unit) post,
        mcomp_sat (f initialL.(getPc)) initialL post ->
        mcomp_sat (Bind getPC f) initialL post.
  Proof. t spec_getPC. Qed.

  Lemma go_setPC: forall initialL v post (f: unit -> M unit),
        mcomp_sat (f tt) (withNextPc v initialL) post ->
        mcomp_sat (Bind (setPC v) f) initialL post.
  Proof.
    intros.
    t (spec_setPC initialL v (fun a' mid' => a' = tt /\ mid' = withNextPc v initialL)).
  Qed.

  Lemma go_step: forall initialL (post: RiscvMachineL -> Prop),
      post (withNextPc (word.add initialL.(getNextPc) (word.of_Z 4))
                       (withPc initialL.(getNextPc) initialL)) ->
      mcomp_sat step initialL post.
  Proof. t spec_step. Qed.

  Lemma go_done: forall initialL (post: RiscvMachineL -> Prop),
      post initialL ->
      mcomp_sat (Return tt) initialL post.
  Proof. intros. apply (spec_Return (Primitives := PR)). exact H. Qed.

  Lemma go_left_identity{A: Type}: forall initialL post a
         (f : A -> M unit),
      mcomp_sat (f a) initialL post ->
      mcomp_sat (Bind (Return a) f) initialL post.
  Proof.
    intros. rewrite left_identity. assumption.
  Qed.

  Lemma go_right_identity: forall initialL post
         (m: M unit),
      mcomp_sat m initialL post ->
      mcomp_sat (Bind m Return) initialL post.
  Proof.
    intros. rewrite right_identity. assumption.
  Qed.

  Lemma go_associativity{A B: Type}: forall initialL post
         (m: M A)
         (f : A -> M B) (g : B -> M unit),
      mcomp_sat (Bind m (fun x : A => Bind (f x) g)) initialL post ->
      mcomp_sat (Bind (Bind m f) g) initialL post.
  Proof.
    intros. rewrite associativity. assumption.
  Qed.

  Definition ptsto_instr(addr: word)(instr: Instruction): mem -> Prop :=
    truncated_scalar Syntax.access_size.four addr (encode instr).

  Definition program(addr: word)(prog: list Instruction): mem -> Prop :=
    array ptsto_instr (word.of_Z 4) addr prog.

  Lemma go_fetch_inst: forall {inst initialL pc0} {R: mem -> Prop} (post: RiscvMachineL -> Prop),
      pc0 = initialL.(getPc) ->
      (program pc0 [inst] * R)%sep initialL.(getMem) ->
      verify inst iset ->
      mcomp_sat (Bind (execute inst) (fun _ => step)) initialL post ->
      mcomp_sat (run1 iset) initialL post.
  Proof.
    intros. subst.
    unfold run1.
    apply go_getPC.
    unfold program, array, ptsto_instr in *.
    eapply go_loadWord.
    - unfold Memory.loadWord.
      eapply load_bytes_of_sep.
      unfold truncated_scalar, littleendian, Memory.bytes_per in H0.
      (* TODO here it would be useful if seplog unfolded Memory.bytes_per for me,
         ie. did more than just syntactic unify *)
      ecancel_assumption.
    - rewrite combine_split.
      assert (0 <= encode inst < 2 ^ width) as F. {
        pose proof (encode_range inst) as P.
        destruct width_cases as [E | E]; rewrite E; split.
        (* TODO if https://github.com/coq/coq/pull/9291 makes it into 8.9.1,
           omega can be replaced by lia *)
        + omega.
        + omega.
        + omega.
        + let r := eval cbv in (2 ^ 32) in change (2 ^ 32) with r in *.
          let r := eval cbv in (2 ^ 64) in change (2 ^ 64) with r in *.
          omega.
      }
      rewrite Z.mod_small; try assumption; try apply encode_range.
      rewrite decode_encode; assumption.
  Qed.

  (* go_load/storeXxx lemmas phrased in terms of separation logic instead of
     Memory.load/storeXxx *)


  Lemma go_loadByte_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v : w8)
           (f : w8 -> M unit) (post : RiscvMachineL -> Prop) (R: mem -> Prop),
      (ptsto_bytes 1 addr v * R)%sep initialL.(getMem) ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (loadByte kind addr) f) initialL post.
  Proof.
    intros.
    eapply go_loadByte; [|eassumption].
    eapply load_bytes_of_sep. eassumption.
  Qed.

  Lemma go_storeByte_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v_old v_new : w8)
           (post : RiscvMachineL -> Prop) (f : unit -> M unit) (R: mem -> Prop),
      (ptsto_bytes 1 addr v_old * R)%sep initialL.(getMem) ->
      (forall m': mem,
          (ptsto_bytes 1 addr v_new * R)%sep m' ->
          mcomp_sat (f tt) (withMem m' initialL) post) ->
      mcomp_sat (Bind (storeByte kind addr v_new) f) initialL post.
  Proof.
    intros.
    pose proof (store_bytes_of_sep (mem_ok := mem_ok)) as P.
    specialize P with (1 := H) (2 := H0).
    destruct P as (m' & P & Q).
    eapply go_storeByte; eassumption.
  Qed.

  Lemma go_loadHalf_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v : w16)
           (f : w16 -> M unit) (post : RiscvMachineL -> Prop) (R: mem -> Prop),
      (ptsto_bytes 2 addr v * R)%sep initialL.(getMem) ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (loadHalf kind addr) f) initialL post.
  Proof.
    intros.
    eapply go_loadHalf; [|eassumption].
    eapply load_bytes_of_sep. eassumption.
  Qed.

  Lemma go_storeHalf_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v_old v_new : w16)
           (post : RiscvMachineL -> Prop) (f : unit -> M unit) (R: mem -> Prop),
      (ptsto_bytes 2 addr v_old * R)%sep initialL.(getMem) ->
      (forall m': mem,
          (ptsto_bytes 2 addr v_new * R)%sep m' ->
          mcomp_sat (f tt) (withMem m' initialL) post) ->
      mcomp_sat (Bind (storeHalf kind addr v_new) f) initialL post.
  Proof.
    intros.
    pose proof (store_bytes_of_sep (mem_ok := mem_ok)) as P.
    specialize P with (1 := H) (2 := H0).
    destruct P as (m' & P & Q).
    eapply go_storeHalf; eassumption.
  Qed.

  Lemma go_loadWord_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v : w32)
           (f : w32 -> M unit) (post : RiscvMachineL -> Prop) (R: mem -> Prop),
      (ptsto_bytes 4 addr v * R)%sep initialL.(getMem) ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (loadWord kind addr) f) initialL post.
  Proof.
    intros.
    eapply go_loadWord; [|eassumption].
    eapply load_bytes_of_sep. eassumption.
  Qed.

  Lemma go_storeWord_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v_old v_new : w32)
           (m': mem) (post : RiscvMachineL -> Prop) (f : unit -> M unit) (R: mem -> Prop),
      (ptsto_bytes 4 addr v_old * R)%sep initialL.(getMem) ->
      (ptsto_bytes 4 addr v_new * R)%sep m' ->
      mcomp_sat (f tt) (withMem m' initialL) post ->
      mcomp_sat (Bind (storeWord kind addr v_new) f) initialL post.
  Proof.
    intros.
    eapply go_storeWord; [|eassumption].
    unfold Memory.storeWord.
    pose proof (unchecked_store_bytes_of_sep (mem_ok := mem_ok)) as P.
    specialize P with (1 := H). specialize (P v_new).
    (* Does not hold because if R does not completely determine the contents of the memory,
       initialL.(getMem) and m' could change in locations other than at addr,
       and post could check for that, so if the post in the hyp requires some specific value
       in m', this value might not be present in initialL.(getMem), and still not be present
       after the storeWord operation, so the conclusion would not hold. *)
  Abort.

  Lemma go_storeWord_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v_old v_new : w32)
           (post : RiscvMachineL -> Prop) (f : unit -> M unit) (R: mem -> Prop),
      (ptsto_bytes 4 addr v_old * R)%sep initialL.(getMem) ->
      (let m' := Memory.unchecked_store_bytes 4 (getMem initialL) addr v_new in
          (ptsto_bytes 4 addr v_new * R)%sep m' ->
          mcomp_sat (f tt) (withMem m' initialL) post) ->
      mcomp_sat (Bind (storeWord kind addr v_new) f) initialL post.
  Proof.
    intros.
    pose proof (unchecked_store_bytes_of_sep (mem_ok := mem_ok)) as P.
    specialize P with (1 := H). specialize (P v_new).
    simpl in *.
    specialize (H0 P).
    eapply go_storeWord; [|eassumption].
    unfold Memory.storeWord, store_bytes.
    erewrite load_bytes_of_sep; eauto using unchecked_store_bytes_of_sep.
  Qed.

  Lemma go_storeWord_sep_holds_but_results_in_evars_out_of_scope:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v_old v_new : w32)
           (post : RiscvMachineL -> Prop) (f : unit -> M unit) (R: mem -> Prop),
      (ptsto_bytes 4 addr v_old * R)%sep initialL.(getMem) ->
      (forall m': mem,
          (ptsto_bytes 4 addr v_new * R)%sep m' ->
          mcomp_sat (f tt) (withMem m' initialL) post) ->
      mcomp_sat (Bind (storeWord kind addr v_new) f) initialL post.
  Proof.
    intros.
    pose proof (store_bytes_of_sep (mem_ok := mem_ok)) as P.
    specialize P with (1 := H) (2 := H0).
    destruct P as (m' & P & Q).
    eapply go_storeWord; eassumption.
  Qed.

  Lemma go_loadDouble_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v : w64)
           (f : w64 -> M unit) (post : RiscvMachineL -> Prop) (R: mem -> Prop),
      (ptsto_bytes 8 addr v * R)%sep initialL.(getMem) ->
      mcomp_sat (f v) initialL post ->
      mcomp_sat (Bind (loadDouble kind addr) f) initialL post.
  Proof.
    intros.
    eapply go_loadDouble; [|eassumption].
    eapply load_bytes_of_sep. eassumption.
  Qed.

  Lemma go_storeDouble_sep:
    forall (initialL : RiscvMachineL) (kind : SourceType) (addr : word) (v_old v_new : w64)
           (post : RiscvMachineL -> Prop) (f : unit -> M unit) (R: mem -> Prop),
      (ptsto_bytes 8 addr v_old * R)%sep initialL.(getMem) ->
      (forall m': mem,
          (ptsto_bytes 8 addr v_new * R)%sep m' ->
          mcomp_sat (f tt) (withMem m' initialL) post) ->
      mcomp_sat (Bind (storeDouble kind addr v_new) f) initialL post.
  Proof.
    intros.
    pose proof (store_bytes_of_sep (mem_ok := mem_ok)) as P.
    specialize P with (1 := H) (2 := H0).
    destruct P as (m' & P & Q).
    eapply go_storeDouble; eassumption.
  Qed.

End Go.


Ltac sidecondition :=
  match goal with
  (* these branches are allowed to instantiate evars in a controlled manner: *)
  | H: map.get _ _ = Some _ |- _ => exact H
  | |- map.get _ _ = Some _ =>
    simpl;
    match goal with
    | |- map.get (map.put _ ?x _) ?y = Some _ =>
      constr_eq x y; apply map.get_put_same
    end
  | |- sep ?P ?Q ?m => simpl in *; solve [seplog]
  | |- _ => reflexivity
  (* but we don't have a general "eassumption" branch, only "assumption": *)
  | |- _ => assumption
  | H: FlatToRiscvDef.valid_instructions _ _ |- Encode.verify ?inst ?iset =>
    assert_fails (is_evar inst);
    apply H; clear; eauto 10 using in_cons, in_or_app, in_eq
  | |- Memory.load ?sz ?m ?addr = Some ?v =>
    simpl; unfold Memory.load, Memory.load_Z;
    erewrite load_bytes_of_sep; [ reflexivity | ecancel_assumption ]
  | |- Memory.store ?sz ?m ?addr ?val = Some ?m' => eassumption
  | |- _ => idtac
  end.

Ltac simulate_step :=
  first (* lemmas packing multiple primitives need to go first: *)
        [ eapply go_fetch_inst     ; [sidecondition..|]
        (* single-primitive lemmas: *)
        (* lemmas about Register0 need to go before lemmas about other Registers *)
        | eapply go_getRegister0   ; [sidecondition..|]
        | eapply go_setRegister0   ; [sidecondition..|]
        | eapply go_getRegister    ; [sidecondition..|]
        | eapply go_setRegister    ; [sidecondition..|]
        (* Note: One might not want these, but a the separation logic version, or
           the version expressed in terms of compile_load/store, so they're commented out
        | eapply go_loadByte       ; [sidecondition..|]
        | eapply go_storeByte      ; [sidecondition..|]
        | eapply go_loadHalf       ; [sidecondition..|]
        | eapply go_storeHalf      ; [sidecondition..|]
        | eapply go_loadWord       ; [sidecondition..|]
        | eapply go_storeWord      ; [sidecondition..|]
        | eapply go_loadDouble     ; [sidecondition..|]
        | eapply go_storeDouble    ; [sidecondition..|]
        *)
        | eapply go_getPC          ; [sidecondition..|]
        | eapply go_setPC          ; [sidecondition..|]
        | eapply go_step           ; [sidecondition..|]
        (* monad law lemmas: *)
        | eapply go_left_identity  ; [sidecondition..|]
        | eapply go_right_identity ; [sidecondition..|]
        | eapply go_associativity  ; [sidecondition..|] ].

Ltac simulate := repeat simulate_step.
