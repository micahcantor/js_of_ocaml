(* Js_of_ocaml compiler
 * http://www.ocsigen.org/js_of_ocaml/
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

 This module provides a global liveness analysis more powerful than that found in [deadcode.ml]. In particular,
 this analysis annotates blocks with the specific fields that are live. It also uses [global_flow.ml] to determine
 the liveness of function return values. It first computes an initial liveness of each variable by traversing the program IR.
 Then it propagates this information to the dependencies of each variable using a flow analysis solver. Lastly it replaces
 dead variables with a sentinal zero variable.

 Although this module does not perform any dead-code elimination itself, it is designed to be used to identify and substitute 
 dead variables that are then removed by [deadcode.ml]. In particular it can allow the elimination of unused functions defined 
 in functors, which the original deadcode elimination cannot. 
 *)

open Code
open Stdlib

let debug = Debug.find "globaldeadcode"

let times = Debug.find "times"

(** Definition of a variable [x]. *)
type def =
  | Expr of expr (* [x] is defined by an expression. *)
  | Param (* [x] is a block or closure parameter. *)

(** Liveness of a variable [x], forming a lattice structure. *)
type live =
  | Top (* [x] is live and not a block. *)
  | Live of IntSet.t (* [x] is a live block with a (non-empty) set of live fields. *)
  | Dead (* [x] is dead. *)

module G = Dgraph.Make_Imperative (Var) (Var.ISet) (Var.Tbl)

module Domain = struct
  type t = live

  let equal l1 l2 =
    match l1, l2 with
    | Top, Top | Dead, Dead -> true
    | Live f1, Live f2 -> IntSet.equal f1 f2
    | _ -> false

  let bot = Dead

  (** Join the liveness according to lattice structure. *)
  let join l1 l2 =
    match l1, l2 with
    | _, Top | Top, _ -> Top
    | Live f1, Live f2 -> Live (IntSet.union f1 f2)
    | Dead, Live f | Live f, Dead -> Live f
    | Dead, Dead -> Dead
end

module Solver = G.Solver (Domain)

let pure_expr pure_funs e = Pure_fun.pure_expr pure_funs e && Config.Flag.deadcode ()

let definitions nv prog =
  let defs = Array.make nv Param in
  let set_def x d = defs.(Var.idx x) <- d in
  Addr.Map.iter
    (fun _ block ->
      (* Add defs from block body *)
      List.iter
        ~f:(fun (i, _) ->
          match i with
          | Let (x, e) -> set_def x (Expr e)
          | Assign (x, _) -> set_def x Param
          | _ -> ())
        block.body)
    prog.blocks;
  defs

(** Type of variable usage. *)  
type usage_kind =
  | Compute (** variable y is used to compute x *)
  | Propagate (** values of y propagate to x *)

(** Compute the adjacency list for the dependency graph of given program. An edge between
    variables [x] and [y] is marked [Compute] if [x] is used in the definition of [y]. It is marked
    as [Propagate] if [x] is applied as a closure or block argument the parameter [y]. 
    
    We use information from global flow to try to add edges between function calls and their return values
    at known call sites. *)
let usages nv prog (global_info : Global_flow.info) : usage_kind Var.Map.t array =
  let uses = Array.make nv Var.Map.empty in
  let add_use kind x y = uses.(Var.idx y) <- Var.Map.add x kind uses.(Var.idx y) in
  let add_arg_dep params args =
    try List.iter2 ~f:(fun x y -> add_use Propagate x y) params args
    with Invalid_argument _ -> ()
  in
  let add_cont_deps (pc, args) =
    match try Some (Addr.Map.find pc prog.blocks) with Not_found -> None with
    | Some block -> add_arg_dep block.params args
    | None -> () (* Dead continuation *)
  in
  let add_expr_uses x e : unit =
    match e with
    | Apply { f; args; _ } ->
        (match Var.Tbl.get global_info.info_approximation f with
        | Top -> ()
        | Values { known; _ } ->
            Var.Set.iter (* For each known closure value of f *)
              (fun k ->
                (* 1. Look at return values, and add edge between x and these values. *)
                (* 2. Add an edge pairwise between the parameters and arguments *)
                match global_info.info_defs.(Var.idx k) with
                | Expr (Closure (params, _)) ->
                    (* If the function is under/over-applied then global flow will mark arguments and return value as escaping.
                       So we only need to consider the case when there is an exact application. *)
                    if List.length params = List.length args
                    then (
                      let return_values = Var.Map.find k global_info.info_return_vals in
                      Var.Set.iter (add_use Propagate x) return_values;
                      List.iter2 ~f:(add_use Propagate) params args)
                | _ -> ())
              known);
        add_use Compute x f;
        (* List.iter ~f:(add_use Compute x) args *)
    | Block (_, vars, _) -> Array.iter ~f:(add_use Compute x) vars
    | Field (z, _) -> add_use Compute x z
    | Constant _ -> ()
    | Closure (_, cont) -> add_cont_deps cont
    | Prim (_, args) ->
        List.iter
          ~f:(fun arg ->
            match arg with
            | Pv v -> add_use Compute x v
            | Pc _ -> ())
          args
  in
  Addr.Map.iter
    (fun _ block ->
      (* Add deps from block body *)
      List.iter
        ~f:(fun (i, _) ->
          match i with
          | Let (x, e) -> add_expr_uses x e
          | Assign (x, y) -> add_use Compute x y
          | Set_field (_, _, _) | Offset_ref (_, _) | Array_set (_, _, _) -> ())
        block.body;
      (* Add deps from block branch *)
      match fst block.branch with
      | Return _ | Raise _ | Stop -> ()
      | Branch cont -> add_cont_deps cont
      | Cond (_, cont1, cont2) ->
          add_cont_deps cont1;
          add_cont_deps cont2
      | Switch (_, a1, a2) ->
          Array.iter ~f:add_cont_deps a1;
          Array.iter ~f:add_cont_deps a2
      | Pushtrap (cont, _, cont_h, _) ->
          add_cont_deps cont;
          add_cont_deps cont_h
      | Poptrap cont -> add_cont_deps cont)
    prog.blocks;
  uses

(** Compute the initial liveness of each variable in the program. 

    A variable [x] is marked as [Top] if 
    + It is used in an impure expression (as defined by [pure_expr]);
    + It is used in a conditonal/switch;
    + It is raised by an exception;
    + It is used in another stateful instruction (like setting a block or array field);
    + Or, it is returned or applied to a function and the global flow analysis marked it as escaping.
    
    A variable [x[i]] is marked as [Live {i}] if it is used in an instruction where field [i] is referenced or set. *)
let liveness nv prog pure_funs (global_info : Global_flow.info) =
  let live_vars = Array.make nv Dead in
  let add_top v =
    let idx = Var.idx v in
    live_vars.(idx) <- Top
  in
  let add_live v i =
    let idx = Var.idx v in
    match live_vars.(idx) with
    | Live fields -> live_vars.(idx) <- Live (IntSet.add i fields)
    | _ -> live_vars.(idx) <- Live (IntSet.singleton i)
  in
  let variable_may_escape x =
    match global_info.info_variable_may_escape.(Var.idx x) with
    | Escape | Escape_constant -> true
    | No -> false
  in
  let live_instruction i =
    match i with
    | Let (x, e) ->
        if not (pure_expr pure_funs e)
        then add_top x
    | Assign (_, _) -> ()
    | Set_field (x, i, y) ->
        add_live x i;
        add_top y
    | Array_set (x, y, z) ->
        add_top x;
        add_top y;
        add_top z
    | Offset_ref (x, i) -> add_live x i
  in
  let live_block block =
    List.iter ~f:(fun (i, _) -> live_instruction i) block.body;
    match fst block.branch with
    | Stop -> ()
    | Return x -> if variable_may_escape x then add_top x
    | Raise (x, _) -> add_top x
    | Cond (x, _, _) -> add_top x
    | Switch (x, _, _) -> add_top x
    | Branch _ | Poptrap _ | Pushtrap _ -> ()
  in
  Addr.Map.iter (fun _ block -> live_block block) prog.blocks;
  live_vars

(* Returns the set of variables given the adjacency list of variable dependencies. *)
let variables deps =
  let vars = Var.ISet.empty () in
  Array.iteri ~f:(fun i _ -> Var.ISet.add vars (Var.of_idx i)) deps;
  vars

(** Propagate liveness of the usages of a variable [x] to [x]. The liveness of [x] is
    defined by joining its current liveness and the contribution of each vairable [y]
    that uses [x]. *)
let propagate uses defs live_vars live_table x =
  let idx = Var.idx x in
  (** Variable [y] uses [x] either in its definition ([Compute]) or as a closure/block parameter
      ([Propagate]). In the latter case, the contribution is simply the liveness of [y]. In the former,
       the contribution depends on the liveness of [y] and its definition. *)
  let contribution y usage_kind =
    match usage_kind with
    (* If x is used to compute y, we consider the liveness of y *)
    | Compute -> (
        match Var.Tbl.get live_table y with
        (* If y is dead, then x is dead. *)
        | Dead -> Dead
        (* If y is a live block, then x is live if it is used in a live field *)
        | Live fields -> (
            match defs.(Var.idx y) with
            | Expr (Block (_, vars, _)) ->
                let found = ref false in
                Array.iteri
                  ~f:(fun i v ->
                    if Var.equal v x && IntSet.mem i fields then found := true)
                  vars;
                if !found then Top else Dead
            | Expr (Field (_, i)) -> Live (IntSet.singleton i)
            | _ -> Top)
        (* If y is top and y is a field access, x depends only on that field *)
        | Top -> (
            match defs.(Var.idx y) with
            | Expr (Field (_, i)) -> Live (IntSet.singleton i)
            | _ -> Top))
    (* If x is used as an argument for parameter y, then contribution is liveness of y *)
    | Propagate -> Var.Tbl.get live_table y
  in
  Var.Map.fold
    (fun y usage_kind live -> Domain.join (contribution y usage_kind) live)
    uses.(idx)
    (Domain.join live_vars.(idx) (Var.Tbl.get live_table x))

let solver vars uses defs live_vars =
  let g =
    { G.domain = vars
    ; G.iter_children = (fun f x -> Var.Map.iter (fun y _ -> f y) uses.(Var.idx x))
    }
  in
  Solver.f () (G.invert () g) (propagate uses defs live_vars)

(** Replace each instance of a dead variable with a sentinal value. 
  Blocks that end in dead variables are compacted to the first live entry. 
  Dead variables are replaced when
    + They appear in a dead field of a block; or
    + They are returned; or
    + They are applied to a function. 
 *)
let zero prog sentinal live_table =
  let compact_vars vars =
    let i = ref (Array.length vars - 1) in
    while !i >= 0 && Var.equal vars.(!i) sentinal do
      i := !i - 1
    done;
    let compacted = Array.make (!i + 1) sentinal in
    Array.blit ~src:vars ~src_pos:0 ~dst:compacted ~dst_pos:0 ~len:(!i + 1);
    compacted
  in
  let is_live v =
    match Var.Tbl.get live_table v with
    | Dead -> false
    | _ -> true
  in
  let zero_var x = if not (is_live x) then sentinal else x in
  let zero_cont ((pc, args) : cont) =
    match Addr.Map.find_opt pc prog.blocks with
    | Some block ->
        let args =
          List.map2
            ~f:(fun param arg -> if is_live param then arg else sentinal)
            block.params
            args
        in
        pc, args
    | None -> pc, args
  in
  let zero_instr instr =
    match instr with
    | Let (x, e) -> (
        match e with
        | Closure (args, cont) ->
            let cont = zero_cont cont in
            Let (x, Closure (args, cont))
        | Block (start, vars, is_array) -> (
            match Var.Tbl.get live_table x with
            | Live fields ->
                let vars =
                  Array.mapi
                    ~f:(fun i v -> if IntSet.mem i fields then v else sentinal)
                    vars
                  |> compact_vars
                in
                let e = Block (start, vars, is_array) in
                Let (x, e)
            | _ -> instr)
        | Apply ap ->
            let args = List.map ~f:zero_var ap.args in
            Let (x, Apply { ap with args })
        | _ -> instr)
    | _ -> instr
  in
  let zero_block block =
    (* Analyze block instructions *)
    let body = List.map ~f:(fun (instr, loc) -> zero_instr instr, loc) block.body in
    (* Analyze branch *)
    let branch =
      let last, loc = block.branch in
      let last =
        match last with
        | Return x -> Return (zero_var x)
        | Raise (_, _) | Stop -> last
        | Branch cont -> Branch (zero_cont cont)
        | Cond (x, cont1, cont2) -> Cond (x, zero_cont cont1, zero_cont cont2)
        | Switch (x, a1, a2) ->
            Switch (x, Array.map ~f:zero_cont a1, Array.map ~f:zero_cont a2)
        | Pushtrap (cont1, x, cont2, pcs) ->
            Pushtrap (zero_cont cont1, x, zero_cont cont2, pcs)
        | Poptrap cont -> Poptrap (zero_cont cont)
      in
      last, loc
    in
    { block with body; branch }
  in
  let blocks = prog.blocks |> Addr.Map.map zero_block in
  { prog with blocks }

module Print = struct
  let live_to_string = function
    | Live fields ->
        "live { " ^ IntSet.fold (fun i s -> s ^ Format.sprintf "%d " i) fields "" ^ "}"
    | Top -> "top"
    | Dead -> "dead"

  let print_uses uses =
    Format.eprintf "Usages:\n";
    Array.iteri
      ~f:(fun i ds ->
        Format.eprintf "%a: { " Var.print (Var.of_idx i);
        Var.Map.iter
          (fun d k ->
            Format.eprintf
              "(%a, %s) "
              Var.print
              d
              (match k with
              | Compute -> "C"
              | Propagate -> "P"))
          ds;
        Format.eprintf "}\n")
      uses

  let print_liveness live_vars =
    Format.eprintf "Liveness:\n";
    Array.iteri ~f:(fun i l -> Format.eprintf "%a: %s\n" Var.print (Var.of_idx i) (live_to_string l)) live_vars

  let print_live_tbl live_table =
    Format.eprintf "Liveness with dependencies:\n";
    Var.Tbl.iter
      (fun v l -> Format.eprintf "%a: %s\n" Var.print v (live_to_string l))
      live_table
end

(** Add a sentinal variable declaration to the IR. The fresh variable is assigned to `undefined`. *)
let add_sentinal p =
  let sentinal = Var.fresh () in
  let undefined = Prim (Extern "%undefined", []) in
  let instr, loc = Let (sentinal, undefined), Before 0 in
  Code.prepend p [ instr, loc ], sentinal

(** Run the liveness analysis and replace dead variables with the given sentinal. *)
let f p sentinal global_info =
  let t = Timer.make () in
  let nv = Var.count () in
  (* Compute definitions *)
  let defs = definitions nv p in
  (* Compute usages *)
  let uses = usages nv p global_info in
  (* Compute initial liveness *)
  let pure_funs = Pure_fun.f p in
  let live_vars = liveness nv p pure_funs global_info in
  (* Propagate liveness to dependencies *)
  let vars = variables uses in
  let live_table = solver vars uses defs live_vars in
  (* Zero out dead fields *)
  let p = zero p sentinal live_table in
  if debug ()
  then (
    Code.Print.program (fun _ _ -> "") p;
    Print.print_liveness live_vars;
    Print.print_uses uses;
    Print.print_live_tbl live_table;
    Format.eprintf "After Elimination:\n";
    Code.Print.program (fun _ _ -> "") p);
  if times () then Format.eprintf "  deadcode dgraph.: %a@." Timer.print t;
  p
