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
 *)

open Code
open Stdlib

type def =
  | Expr of expr
  | Param

type live =
  | Top
  | Live of IntSet.t
  | Dead

module G = Dgraph.Make_Imperative (Var) (Var.ISet) (Var.Tbl)

module Domain = struct
  type t = live

  let equal l1 l2 =
    match l1, l2 with
    | Top, Top | Dead, Dead -> true
    | Live f1, Live f2 -> IntSet.equal f1 f2
    | _ -> false

  let bot = Dead

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

type usage_kind =
  | Compute (* variable y is used to compute x *)
  | Propagate (* values of y propagate to x *)

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
            Var.Set.iter (* For each known value of f *)
              (fun k ->
                (* 1. Look at return values, and add edge between x and these values. *)
                let return_values = Var.Map.find k global_info.info_return_vals in
                Var.Set.iter (add_use Propagate x) return_values;
                (* 2. If k is a closure, add an edge pairwise between the parameters and arguments *)
                match global_info.info_defs.(Var.idx k) with
                | Expr (Closure (params, _)) ->
                    List.iter2 ~f:(add_use Propagate) params args
                | _ -> ())
              known);
        add_use Compute x f
    | Block (_, params, _) -> Array.iter ~f:(add_use Propagate x) params
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
          (* TODO: These? *)
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

(* Return the set of variables used in a given expression *)
let expr_vars e =
  let vars = Var.ISet.empty () in
  (match e with
  | Apply { f; args; _ } ->
      Var.ISet.add vars f;
      List.iter ~f:(Var.ISet.add vars) args
  | Block (_, params, _) -> Array.iter ~f:(Var.ISet.add vars) params
  | Field (z, _) -> Var.ISet.add vars z
  | Constant _ -> ()
  | Closure (params, _) -> List.iter ~f:(Var.ISet.add vars) params
  | Prim (_, args) ->
      List.iter
        ~f:(fun v ->
          match v with
          | Pv v -> Var.ISet.add vars v
          | Pc _ -> ())
        args);
  vars

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
  let live_instruction i =
    match i with
    | Let (x, e) ->
        if not (pure_expr pure_funs e)
        then (
          (* TODO: if e is an impure application, then look at each argument, if they escape then set to top *)
          let vars = expr_vars e in
          Var.ISet.iter add_top vars;
          add_top x;
          match e with
          | Apply { args; _ } ->
              List.iter
                ~f:(fun x -> if Var.ISet.mem global_info.info_may_escape x then add_top x)
                args
          | _ -> ())
    | Assign (_, _) -> ()
    (* TODO: what to do with these? *)
    | Set_field (x, i, y) ->
        add_live x i;
        add_top y
    | Array_set (x, y, z) ->
        add_top x;
        add_top y;
        add_top z
    | Offset_ref (x, i) -> add_live x i
  in
  let rec live_block block =
    List.iter ~f:(fun (i, _) -> live_instruction i) block.body;
    match fst block.branch with
    (* Base Cases *)
    | Stop -> ()
    | Return x -> if Var.ISet.mem global_info.info_may_escape x then add_top x
    | Raise (x, _) -> add_top x
    (* Recursive cases *)
    | Branch cont | Poptrap cont ->
        live_continuation prog cont;
        live_continuation prog cont
    | Pushtrap (cont1, _, cont2, _) ->
        live_continuation prog cont1;
        live_continuation prog cont2
    | Cond (x, cont1, cont2) ->
        add_top x;
        live_continuation prog cont1;
        live_continuation prog cont2
    | Switch (x, a1, a2) ->
        add_top x;
        Array.iter ~f:(fun cont -> live_continuation prog cont) a1;
        Array.iter ~f:(fun cont -> live_continuation prog cont) a2
  and live_continuation prog ((pc, _) : cont) =
    let block = Addr.Map.find pc prog.blocks in
    live_block block
  in
  Addr.Map.iter (fun _ block -> live_block block) prog.blocks;
  live_vars

(* Returns the set of variables given the adjacency list of variable dependencies. *)
let variables deps =
  let vars = Var.ISet.empty () in
  Array.iteri ~f:(fun i _ -> Var.ISet.add vars (Var.of_idx i)) deps;
  vars

let propagate (uses : usage_kind Var.Map.t array) defs live_vars live_table x =
  let idx = Var.idx x in
  let contribution y usage_kind =
    match usage_kind with
    | Compute -> (
        match Var.Tbl.get live_table y with
        | Dead -> Dead (* If x is used in y, and y is dead, then x is dead. *)
        | Top | Live _ -> (
            (* Otherwise we may be able to refine y's liveness. *)
            match defs.(Var.idx y) with
            | Expr (Field (_, i)) -> Live (IntSet.singleton i)
            | _ -> Top))
    | Propagate -> Var.Tbl.get live_table y
  in
  Var.Map.fold
    (fun y usage_kind live -> Domain.join (contribution y usage_kind) live)
    uses.(idx)
    live_vars.(idx)

let solver vars (uses : usage_kind Var.Map.t array) defs live_vars =
  let g =
    { G.domain = vars
    ; G.iter_children = (fun f x -> Var.Map.iter (fun y _ -> f y) uses.(Var.idx x))
    }
  in
  Solver.f () (G.invert () g) (propagate uses defs live_vars)

let eliminate prog live_table =
  let sentinal = Var.fresh () in
  let add_sentinal_instr blocks =
    Addr.Map.update
      0
      (function
        | Some block ->
            let body = (Let (sentinal, Constant (Int 0l)), Before 0) :: block.body in
            Some { block with body }
        | None -> assert false (* Unreachable *))
      blocks
  in
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
  let rec filter_args pl al =
    match pl, al with
    | x :: pl, y :: al -> if is_live x then y :: filter_args pl al else filter_args pl al
    | [], _ -> []
    | _ -> assert false
  in
  let eliminate_cont ((pc, args) : cont) =
    let block = Addr.Map.find pc prog.blocks in
    let args = filter_args block.params args in
    pc, args
  in
  let eliminate_closure instr =
    match instr with
    | Let (x, Closure (args, cont)) -> Let (x, Closure (args, eliminate_cont cont))
    | _ -> instr
  in
  let eliminate_instr instr =
    match instr with
    | Let (x, e) -> (
        match Var.Tbl.get live_table x with
        | Top -> Some instr
        | Live fields -> (
            match e with
            (* Eliminate unused fields from block *)
            | Block (start, vars, is_array) ->
                let vars =
                  Array.mapi
                    ~f:(fun i v -> if IntSet.mem i fields then v else sentinal)
                    vars
                  |> compact_vars
                in
                let e = Block (start, vars, is_array) in
                Some (Let (x, e))
            (* This should never happen *)
            | _ -> None)
        | Dead -> None)
    | Assign (x, _) -> if is_live x then Some instr else None
    | Set_field (_, _, _) | Offset_ref (_, _) | Array_set (_, _, _) -> Some instr
  in
  let update_block block =
    (* Filter dead params *)
    let params = List.filter ~f:is_live block.params in
    (* Analyze block instructions *)
    let body =
      List.filter_map
        ~f:(fun (instr, loc) ->
          Option.map
            ~f:(fun instr -> eliminate_closure instr, loc)
            (eliminate_instr instr))
        block.body
    in
    (* Analyze branch *)
    let branch =
      let last, loc = block.branch in
      let last =
        match last with
        | Return _ | Raise (_, _) | Stop -> last
        | Branch cont -> Branch (eliminate_cont cont)
        | Cond (x, cont1, cont2) -> Cond (x, eliminate_cont cont1, eliminate_cont cont2)
        | Switch (x, a1, a2) ->
            Switch (x, Array.map ~f:eliminate_cont a1, Array.map ~f:eliminate_cont a2)
        | Pushtrap (cont1, x, cont2, pcs) ->
            Pushtrap (eliminate_cont cont1, x, eliminate_cont cont2, pcs)
        | Poptrap cont -> Poptrap (eliminate_cont cont)
      in
      last, loc
    in
    { params; body; branch }
  in
  let blocks = prog.blocks |> Addr.Map.map update_block |> add_sentinal_instr in
  { prog with blocks }

module Print = struct
  let live_to_string = function
    | Live fields ->
        "live { " ^ IntSet.fold (fun i s -> s ^ Format.sprintf "%d " i) fields "" ^ "}"
    | Top -> "top"
    | Dead -> "dead"

  let _print_defs defs =
    Format.eprintf "Definitions:\n";
    Array.iteri
      ~f:(fun i def ->
        Format.eprintf "v%d: " i;
        (match def with
        | Expr e -> Format.eprintf "%a " Print.expr e
        | Param -> Format.eprintf "param");
        Format.eprintf "\n")
      defs

  let print_uses uses =
    Format.eprintf "Usages:\n";
    Array.iteri
      ~f:(fun i ds ->
        Format.eprintf "v%d: { " i;
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
    Array.iteri ~f:(fun i l -> Format.eprintf "v%d: %s\n" i (live_to_string l)) live_vars

  let print_live_tbl live_table =
    Format.eprintf "Liveness with dependencies:\n";
    Var.Tbl.iter
      (fun v l -> Format.eprintf "%a: %s\n" Var.print v (live_to_string l))
      live_table
end

let f p global_info =
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
  (* Print.print_defs defs; *)
  Print.print_uses uses;
  Print.print_liveness live_vars;
  Print.print_live_tbl live_table;
  (* After dependency propagation *)
  let p = eliminate p live_table in
  Format.eprintf "After Elimination:\n";
  Code.Print.program (fun _ _ -> "") p;
  p
