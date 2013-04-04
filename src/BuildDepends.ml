(***************************************************************************)
(*  OASIS2OPAM: Convert OASIS metadata to OPAM package descriptions        *)
(*                                                                         *)
(*  Copyright (C) 2013-2014, Christophe Troestler                          *)
(*                                                                         *)
(*  This library is free software; you can redistribute it and/or modify   *)
(*  it under the terms of the GNU General Public License as published by   *)
(*  the Free Software Foundation; either version 3 of the License, or (at  *)
(*  your option) any later version, with the OCaml static compilation      *)
(*  exception.                                                             *)
(*                                                                         *)
(*  This library is distributed in the hope that it will be useful, but    *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of             *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the file      *)
(*  COPYING for more details.                                              *)
(*                                                                         *)
(*  You should have received a copy of the GNU Lesser General Public       *)
(*  License along with this library; if not, write to the Free Software    *)
(*  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301   *)
(*  USA.                                                                   *)
(***************************************************************************)

open Printf
open OASISTypes
open Utils

module S = Set.Make(String)
module M = Map.Make(String)

let findlib_with_ocaml =
  let pkg = [ "bigarray"; "camlp4"; "dynlink"; "graphics"; "labltk"; "num";
              "ocamlbuild"; "stdlib"; "str"; "threads"; "unix" ] in
  List.fold_left (fun s e -> S.add e s) S.empty pkg

module Opam = struct

  let opam =
    let f_exit_code c =
      if c <> 0 then
        if c = 127 then fatal_error "\"opam\" not found.\n"
        else fatal_error(sprintf "\"opam\" returned the error code %d.\n" c) in
    fun cmd ->
    OASISExec.run_read_one_line
      ~ctxt:!OASISContext.default ~f_exit_code
      "opam" cmd

  let root = opam ["config"; "var"; "root"]

  let space_re = Str.regexp "[ \t\n\r]+"
  let pkg_re = Str.regexp "\\([a-zA-Z0-9_-]+\\)\\.\\(.+\\)\\.opam"
  let findlib_re =
    Str.regexp "\"ocamlfind\" +\"remove\" +\"\\([a-zA-Z0-9_.-]+\\)\""

  let rec add_all_findlib m opam s ofs =
    try
      ignore(Str.search_forward findlib_re s ofs);
      let ofs = Str.match_end() in
      let p = Str.matched_group 1 s in
      let opam_pkgs = try S.add opam (M.find p !m)
                      with Not_found -> S.singleton opam in
      m := M.add p opam_pkgs !m;
      add_all_findlib m opam s ofs
    with Not_found -> ()

  (* FIXME: we may want to track versions and add a constraint ">="
     when a findlib package is provided only be later OPAM versions. *)
  let findlib =
    (* FIXME: Cache result? *)
    let m = ref M.empty in
    let dir = Filename.concat root "opam" in
    let pkg_ver = Sys.readdir dir in
    let add pkg_ver =
      if Str.string_match pkg_re pkg_ver 0 then (
        let opam = Str.matched_group 1 pkg_ver in
        (* let version = Str.matched_group 2 pkg_ver in *)
        let s = read_whole_file (Filename.concat dir pkg_ver) in
        let s = Str.global_replace space_re " " s in
        add_all_findlib m opam s 0;
      ) in
    Array.iter add pkg_ver;
    (* Easier to match on lists: *)
    M.map (fun o -> S.elements o) !m

  (* Return the OPAM package containing the findlib module.  See
     https://github.com/OCamlPro/opam/issues/573 *)
  let of_findlib p v =
    let opam = try M.find p findlib
               with Not_found -> [] in
    (* Assume the findlib and OPAM version constraint coincide
       as it is the case for people using oasis. *)
    (opam, v)
end

(* Gather findlib packages
 ***********************************************************************)

let add_depends_of_build d cond deps =
  let findlib deps = function
    | FindlibPackage(p, v) -> (p, v, cond) :: deps
    | InternalLibrary _ -> deps in
  List.fold_left findlib deps d

let findlib_of_section deps = function
  | Library(_, bs, _)
  | Executable(_, bs, _) ->
     add_depends_of_build bs.bs_build_depends bs.bs_build deps
  | _ -> deps

let rec merge_findlib_depends_sorted = function
  | [_] | [] as deps -> deps
  | (p1, v1, c1) :: (p2, v2, c2) :: tl when p1 = p2 ->
     let v = Version.satisfy_both v1 v2 in
     merge_findlib_depends_sorted ((p1, v, c1 @ c2) :: tl)
  | dep :: tl -> dep :: merge_findlib_depends_sorted tl

let merge_findlib_depends d =
  let d = List.sort (fun (p1,_,_) (p2,_,_) -> String.compare p1 p2) d in
  merge_findlib_depends_sorted d

(* Compulsory and optional findlib packages
 ***********************************************************************)

let get_flags sections =
  let add m = function
    | Flag(cs, f) -> M.add cs.cs_name f.flag_default m
    | _ -> m in
  List.fold_left add M.empty sections

let is_compulsory flags cond =
  (* If any condition returns [true] (i.e. a section with these dep
     must be built), then the dependency is compulsory. *)
  let eval_tst name =
    try
      let t = M.find name flags in
      (* FIXME: how to eval flags? *)
      string_of_bool(OASISExpr.choose (fun _ -> "false") t)
    with Not_found -> "false" in
  OASISExpr.choose eval_tst cond

(* Format OPAM output
 ***********************************************************************)

let output_depend fh (lib, v,_) =
  (* FIXME: must make a reverse search: findlib package → opam package *)
  let opam, v = Opam.of_findlib lib v in
  (* If there is more than one OPAM package providing the library,
     warn the user. *)
  (match opam with
   | [] ->
      fatal_error(sprintf "OPAM package for %S not found." lib)
   | [opam] ->
      fprintf fh "%S " opam;
   | _ ->
      let opam = List.sort String.compare opam in
      (* FIXME: what is a good heuristic to choose among packages
         providing the same lib? *)
      let o = List.hd opam in
      let pkgs = String.concat ", " opam in
      warn(sprintf "%S is provided by OPAM packages %s, chose %S." lib pkgs o);
      fprintf fh "%S " o);
  match v with
  | None -> ()
  | Some v -> fprintf fh "{%s} " (Version.string_of_comparator v)

let output fh pkg =
  let d = List.fold_left findlib_of_section [] pkg.sections in
  let d = merge_findlib_depends d in
  (* filter out the packages coming with OCaml *)
  let d = List.filter (fun (p,_,_) -> not(S.mem p findlib_with_ocaml)) d in
  let flags = get_flags pkg.sections in
  let d, opt = List.partition (fun (_,_,c) -> is_compulsory flags c) d in

  M.iter (fun lib pkg ->
          if List.length pkg > 1 then
            eprintf "# %s -> %s\n" lib (String.concat ", " pkg);
         ) Opam.findlib;

  output_string fh "depends: [ \"ocamlfind\" ";
  List.iter (output_depend fh) d;
  output_string fh "]\n";
  if opt <> [] then (
    output_string fh "depopts: [ ";
    List.iter (output_depend fh) opt;
    output_string fh "]\n";
  )
