(*pp camlp4o -I $PIQI_ROOT/camlp4 pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010 Anton Lavrik

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)


module C = Piqi_common
open C


module R = Piqobj.Record
module F = Piqobj.Field
module V = Piqobj.Variant
module E = Piqobj.Variant
module O = Piqobj.Option
module A = Piqobj.Alias
module Any = Piqobj.Any
module L = Piqobj.List


(*
(* "unknown field" warnings will not be printed for the fields from this list *)
let ignored_fields = ref []


let add_ignored_field x =
  ignored_fields := x :: !ignored_fields


let is_ignored_field (ast :T.ast) =
  match ast with
    | `name x | `named {T.Named.name = x} -> (* field or flag *)
        List.mem x !ignored_fields
    | _ -> false


let load_piq_ignore_field = function
  | `word x ->
      add_ignored_field x
  | x ->
      error x "invalid .piq-ignore entry"


let load_piq_ignore_node (l :T.ast list) =
  try
    let ignore_node = List.find
      (function
        | `named {T.Named.name = "piq-ignore"; T.Named.value = `list l} ->
            add_ignored_field "piq-ignore"; (* add piq-ignore itself *)
            List.iter load_piq_ignore_field l;
            true
        | (`named {T.Named.name = "piq-ignore"} as x) ->
            error x "invalid .piq-ignore specification"
        | _ -> false) l
    in ignore (ignore_node)
  with
    Not_found -> ()


let load_piq_ignore (ast : T.ast) =
  ignored_fields := []; (* reset ignored fields *)
  match ast with
    | `list l -> load_piq_ignore_node l
    | _ -> ()
*)
let delay_unknown_warnings = ref false

let unknown_fields = ref []

let add_unknown_field x =
  unknown_fields := x :: !unknown_fields


let get_unknown_fields () =
  let res = List.rev !unknown_fields in
  (* reset unkown field list state *)
  unknown_fields := [];
  delay_unknown_warnings := false;
  res


(* XXX: resolve_defaults should be disabled by default *)
let resolve_defaults = ref false


(* ------------------------------------------------------------------- *)
(* ------------------------------------------------------------------- *)
(* ------------------------------------------------------------------- *)

let depth = ref 0

(* depth, description, object *)
exception Error of int * string * Obj.t


(* TODO: trace errors *)
let trace_error obj s =
  let loc = location obj in
  trace "piqobj_of_piq error: %s\n" (strerr loc s)


let error obj s =
  (*
  trace_error obj s;
  *)
  raise (Error (!depth, s, Obj.repr obj))


(* TODO, XXX: handle integer overflows *)
let parse_int (obj:T.ast) = match obj with
  | `int x -> `int (Piqloc.addrefret obj x)
  | `uint x -> `uint (Piqloc.addrefret obj x)
  | o -> error o "int constant expected"


let uint64_to_float x =
  if Int64.compare x 0L < 0 (* big unsinged? *)
  then
    let s = Printf.sprintf "%Lu" x in
    float_of_string s
  else
    Int64.to_float x


let parse_float (x:T.ast) = match x with
  | `int x -> Int64.to_float x
  | `uint x -> uint64_to_float x
  | `float x -> x
  | o -> error o "float constant expected"


let parse_bool (x:T.ast) = match x with
  | `bool x -> x
  | o -> error o "boolean constant expected"


let parse_string (x:T.ast) = match x with
  | `ascii_string s | `utf8_string s | `text s -> s
  | `binary s ->
      error s "string contains non-unicode binary data"
  | o -> error o "string expected"


let parse_binary (x:T.ast) = match x with
  | `ascii_string s | `binary s -> s
  | `utf8_string s ->
      error s "binary contains unicode characters or code points"
  | o -> error o "binary expected"


let parse_text (x:T.ast) = match x with
  | `text x -> x
  | o -> error o "text expected"


let parse_word (x:T.ast) = match x with
  | `word x -> x
  | o -> error o "word expected"


(* some common errors *)
let error_exp_list obj = error obj "list expected"

let check_duplicate name tail =
  match tail with
    | [] -> ()
    | l ->
        List.iter (fun obj ->
          warning obj ("duplicate field " ^ quote name)) l


let warn_unknown_field x =
  if !Config.flag_trace
  then
    let s = Piq_gen.to_string x in
    warning x ("unknown field: " ^ s)
  else
    warning x "unknown field"


let handle_unknown_field (x:T.ast) =
  (*
  if is_ignored_field x
  then ()
  else
  *)
  if !delay_unknown_warnings
  then add_unknown_field x
  else warn_unknown_field x


let handle_unknown_variant (x:T.ast) =
  if !Config.flag_trace
  then
    let s = Piq_gen.to_string x in
    error x ("unknown variant: " ^ s)
  else
    error x "unknown variant"


let find_piqtype name =
  try
    Piqi_db.find_piqtype name
  with Not_found ->
    Piqi_common.error name ("unknown type: " ^ quote name)


(* idtable implemented as map: string -> 'a *)
let rec parse_obj0 (t: T.piqtype) (x: T.ast) :Piqobj.obj =
  (* fill the location DB *)
  let r f x = reference f x in
  let rr f t x = reference (f t) x in
  match t with
    (* built-in types *)
    | `int -> parse_int x
    | `float -> `float (r parse_float x)
    | `bool -> `bool (r parse_bool x)
    | `string -> `string (r parse_string x)
    | `binary -> `binary (r parse_binary x)
    | `text -> `text (r parse_text x)
    | `word -> `word (r parse_word x)
    | `any -> `any (r parse_any x)
    (* custom types *)
    | `record t -> `record (rr parse_record t x)
    | `variant t -> `variant (rr parse_variant t x)
    | `enum t -> `enum (rr parse_enum t x)
    | `list t -> `list (rr parse_list t x)
    | `alias t -> `alias (rr parse_alias t x)

and parse_obj t x = reference (parse_obj0 t) x


and parse_typed_obj ?piqtype x = 
  match piqtype, x with
    | None, `typed {T.Typed.typename = n; T.Typed.value = v} ->
        let t = find_piqtype n in
        let ast = some_of v.T.Any#ast in
        parse_obj t ast
    | Some t, `typed {T.Typed.value = v} ->
        (* XXX: if both piqtype and `typed are defined, supplied type overrides
         * object type *)
        (* XXX: produce warning if they are not equal? *)
        let ast = some_of v.T.Any#ast in
        parse_obj t ast
    | Some t, _ ->
        (* it is not a typed object, but we can use a supplied type *)
        parse_obj t x
    | _ -> error x "typed object expected"


and try_parse_obj field_name t x =
  (* unwind alias to obtain its real type *)
  match unalias t with
    | `record _ | `list _ ->
        (* NOTE: all records and lists should be labeled, so try-parsing them
         * always fails *)
        None
    | `any when field_name <> None ->
        (* NOTE, XXX: try-parsing of labeled `any always failes *)
        None
    (* NOTE, XXX: try-parsing of unlabeled `any always succeeds *)
    | _ ->
        let depth' = !depth in
        try Some (parse_obj t x)
        with
          (* ignore errors which occur at the same parse depth, i.e. when
           * parsing everything except for lists and records which increment
           * depth *)
          Error (depth'', _, _) when depth'' = depth' ->
            (depth := depth'; None) (* restore the original depth *)


and parse_any x =
  (* NOTE: the object is not fully resolved during this stage; at least
   * "obj" should be obtained by parsing "piqtype.ast" at later stages (see
   * Piqi.resolve_defaults for example *)
  let piq_any = T.Any#{ ast = Some x; binobj = None } in
  Piqloc.addref x piq_any;
  Any#{ any = piq_any; obj = None }


and parse_record t x =
  match x with
    | `list l ->
        incr depth;
        (* NOTE: pass locating information as a separate parameter since empty
         * list is unboxed and doesn't provide correct location information *)
        let loc = x in
        let res = do_parse_record loc t l in
        decr depth;
        res
    | o -> error_exp_list o
 (*
  * 1. parse required fields first by label, type or (sub)type = anonymous
  * 2. parse the rest in the order they are listed in the original specification
  * 
  *
  *)

and do_parse_record loc t l =
  let required_spec, other_spec =
    List.partition is_required_field t.T.Record#field in
  (* parse required fields first *)
  let fields, rem =
    List.fold_left (parse_field loc) ([], l) (required_spec @ other_spec) in
  (* issue warnings on unparsed fields *)
  List.iter handle_unknown_field rem;
  (* put required fields back at the top *)
  R#{ piqtype = t; field = List.rev fields}


and is_required_field t = (t.T.Field#mode = `required)


and parse_field loc (accu, rem) t =
  let fields, rem =
    match t.T.Field#typeref with
      | None -> do_parse_flag t rem
      | Some _ -> do_parse_field loc t rem
  in
  (List.rev_append fields accu, rem)


and do_parse_flag t l =
  let open T.Field in
  let name = name_of_field t in
  debug "do_parse_flag: %s\n" name;
  let res, rem = find_flags name l in
  match res with
    | [] -> [], rem
    | x::tail ->
        check_duplicate name tail;
        let res = F#{ piqtype = t; obj = None } in
        Piqloc.addref x res;
        [res], rem


and do_parse_field loc t l =
  let open T.Field in
  let name = name_of_field t in
  debug "do_parse_field: %s\n" name;
  let field_name = t.name in
  let field_type = piqtype (some_of t.typeref) in
  let values, rem =
    match t.mode with
      | `required -> 
          let x, rem = parse_required_field loc name field_name field_type l in
          [x], rem
      | `optional ->
          let default =
            if !resolve_defaults
            then t.default
            else None
          in
          let x, rem = parse_optional_field name field_name field_type default l in
          let res = (match x with Some x -> [x] | None -> []) in
          res, rem
      | `repeated ->
          parse_repeated_field name field_name field_type l
  in
  let fields =
    List.map (fun x ->
      let res = F#{ piqtype = t; obj = Some x } in
      Piqloc.addrefret x res) values
  in
  fields, rem
  

and parse_required_field loc name field_name field_type l =
  let res, rem = find_fields name l in
  match res with
    | [] ->
        (* try finding the first field which is successfully parsed by
         * 'parse_obj' for a given field type *)
        begin
          let res, rem = find_first_parsed field_name field_type l in
          match res with
            | Some x -> x, rem
            | None -> error loc ("missing field " ^ quote name)
        end
    | x::tail ->
        check_duplicate name tail;
        parse_obj field_type x, rem


(* find field by name, return found fields and remaining fields *)
and find_fields (name:string) (l:T.ast list) :(T.ast list * T.ast list) =
  let rec aux accu rem = function
    | [] -> List.rev accu, List.rev rem
    | (`named n)::t when n.T.Named#name = name -> aux (n.T.Named#value::accu) rem t
    | h::t -> aux accu (h::rem) t
  in
  aux [] [] l


(* find flags by name, return found flags and remaining fields *)
and find_flags (name:string) (l:T.ast list) :(string list * T.ast list) =
  let rec aux accu rem = function
    | [] -> List.rev accu, List.rev rem
    | (`name n)::t when n = name -> aux (n::accu) rem t
    | (`named n)::t when n.T.Named#name = name ->
        error n "value can not be specified for a flag"
    | h::t -> aux accu (h::rem) t
  in
  aux [] [] l


and find_first_parsed field_name field_type l =
  let rec aux rem = function
    | [] -> None, l
    | h::t ->
        match try_parse_obj field_name field_type h with
          | None -> aux (h::rem) t
          | x -> x, (List.rev rem) @ t
  in aux [] l


and parse_optional_field name field_name field_type default l =
  let res, rem = find_fields name l in
  match res with
    | [] ->
        (* try finding the first field which is successfully parsed by
         * 'parse_obj for a given field_type' *)
        begin
          let res, rem = find_first_parsed field_name field_type l in
          match res, default with
            | None, Some x ->
                (* XXX: parsing the same default from ast each time is
                 * relatively expensive, we might think of just converting
                 * default to obj and picking it *)
                let default_ast = some_of x.T.Any.ast in
                Piqloc.check_add_fake_loc default_ast ~label:"_piqobj_of_piq_default";
                Some (parse_obj field_type default_ast), l (* parse default *)
            | _ -> res, rem
        end
    | x::tail ->
        check_duplicate name tail;
        Some (parse_obj field_type x), rem


(* parse repeated variant field allowing variant names if field name is
 * unspecified *) 
and parse_repeated_field name field_name field_type l =
  let res, rem = find_fields name l in
  match res with
    | [] -> 
        (* XXX: ignore errors occuring when unknown element is present in the
         * list allowing other fields to find their members among the list of
         * elements *)
        let accu, rem =
          (List.fold_left
            (fun (accu, rem) x ->
              match try_parse_obj field_name field_type x with
                | None -> accu, x::rem
                | Some x -> x::accu, rem) ([], []) l)
        in List.rev accu, List.rev rem
    | l ->
        (* use strict parsing *)
        let res = List.map (parse_obj field_type) res in
        res, rem


and parse_variant t x =
  debug "parse_variant: %s\n" t.T.Variant#name;
  let options = t.T.Variant#option in
  try
    let value =
      match x with
        | `name n ->
            parse_name_option options n
        | `word _ ->
            parse_word_option options x
        | `bool _ ->
            parse_bool_option options x
        | `int _ ->
            parse_int_option options x
        | `float _ ->
            parse_float_option options x
        | `ascii_string _ | `utf8_string _ | `binary _ ->
            parse_string_option options x
        | `text _ ->
            parse_text_option options x
        | `named {T.Named.name = n; T.Named.value = x} ->
            parse_named_option options n x
        | `list _ ->
            parse_list_option options x
        | o -> error o "invalid option"
    in
    Piqloc.addref x value;
    V#{ piqtype = t; option = value }
  with Not_found ->
    (* recurse through included co-variants *)
    (* XXX: aliased variants are contra-variants? *)
    let is_covariant o =
      let open T.Option in
      match o.name, o.typeref with
        | None, Some (`variant _) -> true (* co-variant *)
        | None, Some (`enum _) -> true (* co-variant *)
        | _ -> false (* contra-variant *)
    in
    let get_covariant o =
      let open T.Option in
      let v =
        match o.typeref with
          | Some (`variant v) -> v
          | Some (`enum v) -> v
          | _ -> assert false
      in (o, v)
    in
    let covariants =
      (List.map get_covariant
        (List.filter is_covariant options))
    in
    let value = parse_covariants covariants x in
    Piqloc.addref x value;
    V#{ piqtype = t; option = value }


and parse_covariants covariants x =
  let rec aux = function
    | [] ->
        (* failed to parse among variant and its covariants *)
        handle_unknown_variant x
    | h::t ->
        try
          parse_covariant h x
        with Not_found -> aux t
  in aux covariants


and parse_covariant (o, v) x =
  let value = reference (parse_variant v) x in
  O#{ piqtype = o; obj = Some (`variant value) }


and parse_name_option options name =
  let f o =
    let open T.Option in
    match o.name, o.typeref with
      | Some n, Some _ when n = name ->
          error name "option value expected" 
      | Some n, None -> n = name 
      | _, _ -> false
  in
  let option = List.find f options in
  O#{ piqtype = option; obj = None }


and parse_named_option options name x =
  let f o =
    let open T.Option in
    match o.name, o.typeref with
      | Some n, None when n = name ->
          error x "unexpected option value"
      | Some n, Some _ -> n = name 
      | None, Some t when piqi_typerefname t = name -> true
      | _, _ -> false
  in parse_typed_option options f x


and make_option_finder f o =
  let open T.Option in
  match o.typeref with
    | None -> false
    | Some x -> f (unalias (piqtype x))


and parse_bool_option options x =
  let f = make_option_finder ((=) `bool) in
  parse_typed_option options f x


and parse_int_option options x =
  let f = make_option_finder (function `int | `float -> true | _ -> false) in
  parse_typed_option options f x


and parse_float_option options x =
  let f = make_option_finder ((=) `float) in
  parse_typed_option options f x


and parse_word_option options x =
  let f = make_option_finder ((=) `word) in
  parse_typed_option options f x


and parse_string_option options x =
  let f = make_option_finder (function `string | `binary -> true | _ -> false) in
  parse_typed_option options f x


and parse_text_option options x =
  let f = make_option_finder (function `string | `text -> true | _ -> false) in
  parse_typed_option options f x


and parse_list_option options x =
  let f = make_option_finder (function `record _ | `list _ -> true | _ -> false) in
  parse_typed_option options f x


and parse_typed_option (options:T.Option.t list) f (x:T.ast) :Piqobj.Option.t =
  let option = List.find f options in
  let option_type = piqtype (some_of option.T.Option#typeref) in
  O#{ piqtype = option; obj = Some (parse_obj option_type x) }


and parse_enum t x = parse_variant t x


and parse_list t = function
  | `list l ->
      incr depth;
      let res = do_parse_list t l in
      decr depth;
      res
  | o -> error_exp_list o


and do_parse_list t l =
  let obj_type = piqtype t.T.Piqlist#typeref in
  let contents = List.map (parse_obj obj_type) l in
  L#{ piqtype = t; obj = contents }


(* XXX: roll-up multiple enclosed aliases into one? *)
and parse_alias t x =
  let obj_type = piqtype t.T.Alias#typeref in
  let obj = parse_obj obj_type x in
  A#{ piqtype = t; obj = obj }


(* 
 * External interface:
 *      resolve parse_obj errors into common parse error format
 *)
let wrap f x =
  depth := 0; (* reset the parser's depth *)
  (*
  load_piq_ignore x; (* load ignored fields from the toplevel list *)
  *)
  try f x
  with Error (_depth, s, obj) ->
    (* print delayed warnings in case of error *) 
    List.iter warn_unknown_field (get_unknown_fields ());
    Piqi_common.error obj s


let parse_obj t x =
  wrap (parse_obj t) x


let parse_typed_obj ?piqtype x =
  wrap (parse_typed_obj ?piqtype) x

