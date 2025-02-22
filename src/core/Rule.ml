(* Yoann Padioleau
 *
 * Copyright (C) 2019-2023 Semgrep Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)
open Common
module MV = Metavariable

let logger = Logging.get_logger [ __MODULE__ ]

open Ppx_hash_lib.Std.Hash.Builtin

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Data structures to represent a Semgrep rule (=~ AST of a rule).
 *
 * See also Mini_rule.ml where formula and many other features disappear.
 *)

(*****************************************************************************)
(* Position information *)
(*****************************************************************************)

(* This is similar to what we do in AST_generic to get precise
 * error location when a rule is malformed (and also to get some
 * special equality and hashing; see the comment for Tok.t_always_equal
 * in Tok.mli)
 *)
type tok = Tok.t_always_equal [@@deriving show, eq, hash]
type 'a wrap = 'a * tok [@@deriving show, eq, hash]

(* To help report pattern errors in the playground *)
type 'a loc = {
  pattern : 'a;
  t : tok;
  path : string list; (* path to pattern in YAML rule *)
}
[@@deriving show, eq]

(*****************************************************************************)
(* Formula (patterns boolean composition) *)
(*****************************************************************************)

(* Classic boolean-logic/set operators with text range set semantic.
 * The main complication is the handling of metavariables and especially
 * negation in the presence of metavariables.
 *
 * less? enforce invariant that Not can only appear in And?
 *
 * We use 'deriving hash' for formula because of the
 * Match_tainting_mode.Formula_tbl formula cache.
 *)
type formula =
  | P of Xpattern.t (* a leaf pattern *)
  | And of tok * conjunction
  | Or of tok * formula list
  (* There are currently restrictions on where a Not can appear in a formula.
   * It must be inside an And to be intersected with "positive" formula.
   * TODO? Could this change if we were moving to a different range semantic?
   *)
  | Not of tok * formula
  (* pattern: and pattern-inside: are actually slightly different so
   * we need to keep the information around.
   * (see tests/rules/inside.yaml)
   * The same is true for pattern-not and pattern-not-inside
   * (see tests/rules/negation_exact.yaml)
   * todo: try to remove this at some point, but difficult. See
   * https://github.com/returntocorp/semgrep/issues/1218
   *)
  | Inside of tok * formula

(* The conjunction must contain at least
 * one positive "term" (unless it's inside a CondNestedFormula, in which
 * case there is not such a restriction).
 * See also split_and().
 *)
and conjunction = {
  (* pattern-inside:'s and pattern:'s *)
  conjuncts : formula list;
  (* metavariable-xyz:'s *)
  conditions : (tok * metavar_cond) list;
  (* focus-metavariable:'s *)
  focus : focus_mv_list list;
}

and metavar_cond =
  | CondEval of AST_generic.expr (* see Eval_generic.ml *)
  (* todo: at some point we should remove CondRegexp and have just
   * CondEval, but for now there are some
   * differences between using the matched text region of a metavariable
   * (which we use for MetavarRegexp) and using its actual value
   * (which we use for MetavarComparison), which translate to different
   * calls in Eval_generic.ml
   * update: this is also useful to keep separate from CondEval for
   * the "regexpizer" optimizer (see Analyze_rule.ml).
   *)
  | CondRegexp of
      MV.mvar * Xpattern.regexp_string * bool (* constant-propagation *)
  | CondType of
      MV.mvar
      * Xlang.t option (* when the type expression is in different lang *)
      * string (* raw input string saved for regenerating rule yaml *)
      * AST_generic.type_ (* LATER: could parse lazily, like the patterns *)
  | CondAnalysis of MV.mvar * metavar_analysis_kind
  | CondNestedFormula of MV.mvar * Xlang.t option * formula

and metavar_analysis_kind = CondEntropy | CondReDoS

(* Represents all of the metavariables that are being focused by a single
   `focus-metavariable`. *)
and focus_mv_list = tok * MV.mvar list [@@deriving show, eq, hash]

(*****************************************************************************)
(* Taint-specific types *)
(*****************************************************************************)

(* We roll our own Boolean formula type here for convenience, it is simpler to
   * inspect and manipulate, and we can safely use polymorphic 'compare' on it.
*)
type precondition =
  | PLabel of string
  | PBool of bool
  | PAnd of precondition list
  | POr of precondition list
  | PNot of precondition
[@@deriving show, ord]

type precondition_with_range = {
  precondition : precondition;
  range : (Tok.location * Tok.location) option;
}
[@@deriving show]

(* The sources/sanitizers/sinks used to be a simple 'formula list',
 * but with taint labels things are bit more complicated.
 *)
type taint_spec = {
  sources : tok * taint_source list;
  sanitizers : (tok * taint_sanitizer list) option;
  sinks : tok * taint_sink list;
  propagators : taint_propagator list;
}

and taint_source = {
  source_formula : formula;
  source_by_side_effect : bool;
  source_control : bool;
  label : string;
      (* The label to attach to the data.
       * Alt: We could have an optional label instead, allow taint that is not
       * labeled, and allow sinks that work for any kind of taint? *)
  source_requires : precondition_with_range option;
      (* A Boolean expression over taint labels, using Python syntax
       * (see Parse_rule). The operators allowed are 'not', 'or', and 'and'.
       *
       * The expression that is being checked as a source must satisfy this
       * in order to the label to be produced. Note that with 'requires' a
       * taint source behaves a bit like a propagator. *)
}

(* Note that, with taint labels, we can attach a label "SANITIZED" to the
 * data to flag that it has been sanitized... so do we still need sanitizers?
 * I am not sure to be honest, I think we will have to gain some experience in
 * using labels first.
 * Sanitizers do allow you to completely remove taint from data, although I
 * think that can be simulated with labels too. We could translate (internally)
 * `pattern-sanitizers` as `pattern-sources` with a `"__SANITIZED__"` label,
 * and then rewrite the `requires` of all sinks as `(...) not __SANITIZED__`.
 * But not-conflicting sanitizers cannot be simulated that way. That said, I
 * think we should replace not-conflicting sanitizers with some `options:`,
 * because they are a bit confusing to use sometimes.
 *)
and taint_sanitizer = {
  sanitizer_formula : formula;
  sanitizer_by_side_effect : bool;
  not_conflicting : bool;
      (* If [not_conflicting] is enabled, the sanitizer cannot conflict with
       * a sink or a source (i.e., match the exact same range) otherwise
       * it is filtered out. This allows to e.g. declare `$F(...)` as a
       * sanitizer, to assume that any other function will handle tainted
       * data safely.
       * Without this, `$F(...)` would automatically sanitize any other
       * function call acting as a sink or a source.
       *
       * THINK: In retrospective, I'm not sure this was a good idea.
       * We should add an option to disable the assumption that function
       * calls always propagate taint, and deprecate not-conflicting
       * sanitizers.
       *)
}

and taint_sink = {
  sink_id : string;  (** See 'Parse_rule.parse_taint_sink'. *)
  sink_formula : formula;
  sink_requires : precondition_with_range option;
      (* A Boolean expression over taint labels. See also 'taint_source'.
       * The sink will only trigger a finding if the data that reaches it
       * has a set of labels attached that satisfies the 'requires'.
       *)
}

(* e.g. if we want to specify that adding tainted data to a `HashMap` makes
 *  the `HashMap` tainted too, then "formula" could be `(HashMap $H).add($X)`,
 * with "from" being `$X` and "to" being `$H`. So if `$X` is tainted then `$H`
 * will also be marked as tainted.
 *)
and taint_propagator = {
  propagator_formula : formula;
  propagator_by_side_effect : bool;
  from : MV.mvar wrap;
  to_ : MV.mvar wrap;
  propagator_requires : precondition_with_range option;
      (* A Boolean expression over taint labels. See also 'taint_source'.
       * This propagator will only propagate taint if the incoming taint
       * satisfies the 'requires'.
       *)
  propagator_replace_labels : string list option;
      (* A list of the particular labels of taint to be replaced by
         the propagator.
         Does nothing if [propagator_label] is not also specified.
         If not specified, all kinds are propagated.
      *)
  propagator_label : string option;
      (* If [propagator_label] is specified, then the propagator will
         output taint with the given label.
         Otherwise, it will output taint with the same label as it
         received.
      *)
}
[@@deriving show]

let default_source_label = "__SOURCE__"
let default_source_requires = PBool true
let default_propagator_requires = PBool true

let get_source_precondition { source_requires; _ } =
  match source_requires with
  | None -> default_source_requires
  | Some { precondition; _ } -> precondition

let get_propagator_precondition { propagator_requires; _ } =
  match propagator_requires with
  | None -> default_propagator_requires
  | Some { precondition; _ } -> precondition

let get_sink_requires { sink_requires; _ } =
  match sink_requires with
  | None -> PLabel default_source_label
  | Some { precondition; _ } -> precondition

(*****************************************************************************)
(* Extract mode (semgrep as a preprocessor) *)
(*****************************************************************************)

type extract = {
  formula : formula;
  dst_lang : Xlang.t;
  (* e.g., $...BODY, $CMD *)
  extract : MV.mvar;
  extract_rule_ids : extract_rule_ids option;
  (* map/reduce *)
  transform : extract_transform;
  reduce : extract_reduction;
}

(* SR wants to be able to choose rules to run on.
   Behaves the same as paths. *)
and extract_rule_ids = {
  required_rules : Rule_ID.t wrap list;
  excluded_rules : Rule_ID.t wrap list;
}

(* Method to transform extracted content:
    - either treat them as a raw string; or
    - transform JSON array into a raw string
*)
and extract_transform = NoTransform | Unquote | ConcatJsonArray

(* Method to combine extracted ranges within a file:
    - either treat them as separate files; or
    - concatentate them together
*)
and extract_reduction = Separate | Concat [@@deriving show]

(*****************************************************************************)
(* secrets mode *)
(*****************************************************************************)

(* This type encodes a basic HTTP request; mainly used for in the secrets
 * post-processor; such that a basic http request like
 * GET semgrep.dev
 * Auth: ok
 * Type: tau
 * would be represented as
 * {
 *   url     = semgrep.dev/user;
 *   meth    = `GET;
 *   headers =
 *  [
 *    { n = Auth, v = ok};
 *    { n = Type, v = tau};
 *  ]
 * }
 * NOTE: we don't reuse cohttp's abstract type Cohttp.Headers.t; we still need
 * it to not be abstract for metavariable substitution.
 *)

type header = { name : string; value : string } [@@deriving show]
type meth = [ `DELETE | `GET | `POST | `HEAD | `PUT ] [@@deriving show]

(* Used to request additional auth headers are computed and added automatically,
 * e.g., because they depend on other headers and/or body
 *
 * For instance, AWS requires signed requests for non-anonymous requests. This
 * entails generating an HMAC based on the body, current time, and a subset of
 * the headers. For us, the headers and body might be generated by
 * interpolating metavariables, so this isn't something which can just be
 * statically added to the rule easily (current time also presents an issue
 * here). Thus, we need a way to have this be added to the generated HTTP frame.
 *)
type auth =
  (* Adds headers required as described in
   * <https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html>
   *)
  | AWS_SIGV4 of {
      secret_access_key : string;
      access_key_id : string;
      service : string;
      region : string;
    }
[@@deriving show]

(* why is url : string? metavariables (i.e http://$X) are present at parsing; which
 * if parsed with Uri.of_string translates it to http://%24x
 *)
type request = {
  url : string;
  meth : meth;
  headers : header list;
  body : string option;
  auth : auth option;
}
[@@deriving show]

(* Used to match on the returned response of some request *)
type response = { return_code : int; regex : Xpattern.regexp_string option }
[@@deriving show]

type secrets = {
  (* postprocessor-patterns:
   * Each pattern in this list represents a piece of a "secret"; with any
   * bindings made available in the request post matching.
   *)
  secrets : formula list;
  request : request;
  response : response;
}
[@@deriving show]

(*****************************************************************************)
(* Languages definition *)
(*****************************************************************************)

(*
   For historical reasons, the 'languages' field in the Semgrep rule
   (YAML file) is a list of strings. There was no distinction between
   target selection and target analysis. This led to oddities for
   analyzers that aren't specific to a programming language.

   We can now start to decouple file filtering from their analysis.
   For example, we can select Bash files using the predefined
   rules that inspect the file extension or the shebang line
   but analyze them using a regexp instead of a regular Semgrep pattern.

   This is the beginning of fixing this giant mess.

   to be continued...
*)
type languages = {
  (* How to select target files e.g. "files that look like C files".
     If unspecified, the selector selects all the files that are not
     ignored by generic mechanisms such as semgrepignore.
     In a Semgrep rule where a string is expected, the standard way
     is to use "generic" but "regex" and "none" have the same effect.
     They all translate into 'None'.

     Example:

       target_selector = Some [Javascript; Typescript];

     ... selects all the files that can be parsed and analyzed
     as TypeScript ( *.js, *.ts, *.tsx) since TypeScript is an extension of
     JavaScript.

     TODO: instead of always deriving this field automatically from
     the 'languages' field of the rule, add support for an optional
     'target-selectors' field that supports a variety of predefined
     target selectors (e.g. "minified-javascript-files",
     "javascript-executable-scripts", "makefile", ...). This would reduce
     the maintenance burden for custom target selectors and allow mixing
     them other target analyzers. For example, we could select all the
     Bash scripts but analyze them with spacegrep.
  *)
  target_selector : Lang.t list option;
  (* How to analyze target files. The accompanying patterns are specified
     elsewhere in the rule.
     Examples:
     - "pattern for the C parser using the generic AST" (regular programming
       language using a classic Semgrep pattern)
     - "pattern for Fortran77 or for Fortran90" (two possible parsers)
     - "spacegrep pattern"
     - "high-entropy detection" (doesn't use a pattern)
     - "extract JavaScript snippets from a PDF file" (doesn't use a pattern)
     This information may have to be extracted from another part of the
     YAML rule.

     Example:

       target_analyzer = L (Typescript, []);
  *)
  target_analyzer : Xlang.t;
}
[@@deriving show]

(*****************************************************************************)
(* Paths *)
(*****************************************************************************)

(* TODO? store also the compiled glob directly? but we preprocess the pattern
 * in Filter_target.filter_paths, so we would need to recompile it anyway,
 * or call Filter_target.filter_paths preprocessing in Parse_rule.ml
 *)
type glob = string (* original string *) * Glob.Pattern.t (* parsed glob *)
[@@deriving show]

(* TODO? should we provide a pattern-path: Xpattern to combine
 * with other Xpattern instead of adhoc paths: extra field in the rule?
 *)
type paths = {
  (* If not empty, list of file path patterns (globs) that
   * the file path must at least match once to be considered for the rule.
   * Called 'include' in our doc but really it is a 'require'.
   * TODO? use wrap? to also get location of include/require field?
   *)
  require : glob list;
  (* List of file path patterns we want to exclude. *)
  exclude : glob list;
}
[@@deriving show]

(*****************************************************************************)
(* Shared mode definitions *)
(*****************************************************************************)

(* Polymorhic variants used to improve type checking of rules (see below) *)
type search_mode = [ `Search of formula ] [@@deriving show]
type taint_mode = [ `Taint of taint_spec ] [@@deriving show]
type extract_mode = [ `Extract of extract ] [@@deriving show]
type secrets_mode = [ `Secrets of secrets ] [@@deriving show]

(* Steps mode includes rules that use search_mode and taint_mode.
 * Later, if we keep it, we might want to make all rules have steps,
 * but for the experiment this is easier to remove.
 *)
type steps_mode = [ `Steps of step list ] [@@deriving show]

(*****************************************************************************)
(* Steps mode *)
(*****************************************************************************)
and step = {
  step_mode : mode_for_step;
  step_languages : languages;
  step_paths : paths option;
}

and mode_for_step = [ search_mode | taint_mode ] [@@deriving show]

(*****************************************************************************)
(* The rule *)
(*****************************************************************************)

type 'mode rule_info = {
  (* MANDATORY fields *)
  id : Rule_ID.t wrap;
  mode : 'mode;
  (* Range of Semgrep versions supported by the rule.
     Note that a rule with these fields may not even be parseable
     in the current version of Semgrep and wouldn't even reach this point. *)
  min_version : Version_info.t option;
  max_version : Version_info.t option;
  (* Currently a dummy value for extract mode rules *)
  message : string;
  (* Currently a dummy value for extract mode rules *)
  severity : severity;
  (* This is the list of languages in which the root pattern makes sense. *)
  languages : languages;
  (* OPTIONAL fields *)
  options : Rule_options.t option;
  (* deprecated? todo: parse them *)
  equivalences : string list option;
  fix : string option;
  fix_regexp : (Xpattern.regexp_string * int option * string) option;
  paths : paths option;
  (* ex: [("owasp", "A1: Injection")] but can be anything *)
  metadata : JSON.t option;
}

(* TODO? just reuse Error_code.severity *)
and severity = Error | Warning | Info | Inventory | Experiment
[@@deriving show]

(* Step mode includes rules that use search_mode and taint_mode *)
(* Later, if we keep it, we might want to make all rules have steps,
   but for the experiment this is easier to remove *)

type mode =
  [ search_mode | taint_mode | extract_mode | secrets_mode | steps_mode ]
[@@deriving show]

(* the general type *)
type rule = mode rule_info [@@deriving show]

(* aliases *)
type t = rule [@@deriving show]
type rules = rule list [@@deriving show]
type hrules = (Rule_ID.t, t) Hashtbl.t

(* If you know your function accepts only a certain kind of rule,
 * you can use those precise types below.
 *)
type search_rule = search_mode rule_info [@@deriving show]
type taint_rule = taint_mode rule_info [@@deriving show]
type extract_rule = extract_mode rule_info [@@deriving show]
type secrets_rule = secrets_mode rule_info [@@deriving show]
type steps_rule = steps_mode rule_info [@@deriving show]

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let hrules_of_rules (rules : t list) : hrules =
  rules |> Common.map (fun r -> (fst r.id, r)) |> Common.hash_of_list

let partition_rules (rules : rules) :
    search_rule list
    * taint_rule list
    * extract_rule list
    * secrets_rule list
    * steps_rule list =
  let rec part_rules search taint extract secrets step = function
    | [] ->
        ( List.rev search,
          List.rev taint,
          List.rev extract,
          List.rev secrets,
          List.rev step )
    | r :: l -> (
        match r.mode with
        | `Search _ as s ->
            part_rules
              ({ r with mode = s } :: search)
              taint extract secrets step l
        | `Taint _ as t ->
            part_rules search
              ({ r with mode = t } :: taint)
              extract secrets step l
        | `Extract _ as e ->
            part_rules search taint
              ({ r with mode = e } :: extract)
              secrets step l
        | `Secrets _ as s ->
            part_rules search taint extract
              ({ r with mode = s } :: secrets)
              step l
        | `Steps _ as j ->
            part_rules search taint extract secrets
              ({ r with mode = j } :: step)
              l)
  in
  part_rules [] [] [] [] [] rules

(*****************************************************************************)
(* Error Management *)
(*****************************************************************************)

(* This is used to let the user know which rule the engine was using when
 * a Timeout or OutOfMemory exn occured.
 *)
let last_matched_rule : Rule_ID.t option ref = ref None

(* Those are recoverable errors; We can just skip the rules containing them.
 * TODO? put in Output_from_core.atd?
 *)
type invalid_rule_error = invalid_rule_error_kind * Rule_ID.t * Tok.t

and invalid_rule_error_kind =
  | InvalidLanguage of string (* the language string *)
  (* TODO: the Parse_info.t for InvalidPattern is not precise for now;
   * it corresponds to the start of the pattern *)
  | InvalidPattern of
      string (* pattern *)
      * Xlang.t
      * string (* exn *)
      * string list (* yaml path *)
  | InvalidRegexp of string (* PCRE error message *)
  | DeprecatedFeature of string (* e.g., pattern-where-python: *)
  | MissingPositiveTermInAnd
  | IncompatibleRule of
      Version_info.t (* this version of Semgrep *)
      * (Version_info.t option (* minimum version supported by this rule *)
        * Version_info.t option (* maximum version *))
  | MissingPlugin of string (* error message *)
  | InvalidOther of string
[@@deriving show]

(* General errors *)
type error_kind =
  | InvalidRule of invalid_rule_error
  | InvalidYaml of string * Tok.t
  | DuplicateYamlKey of string * Tok.t
  | UnparsableYamlException of string

type error = {
  (* Some errors are in the YAML file before we can enter a specific rule
     or it could be a rule without an ID. This is why the rule ID is
     optional. *)
  rule_id : Rule_ID.t option;
  kind : error_kind;
}

exception Error of error

(*
   You must provide a rule ID for a rule to be reported properly as an invalid
   rule. The argument is not optional because it's important to not forget to
   specify a rule ID whenever possible.
*)
let raise_error optional_rule_id kind =
  raise (Error { rule_id = optional_rule_id; kind })

(*****************************************************************************)
(* String-of *)
(*****************************************************************************)

let string_of_invalid_rule_error_kind = function
  | InvalidLanguage language -> spf "invalid language %s" language
  | InvalidRegexp message -> spf "invalid regex %s" message
  (* coupling: this is actually intercepted in
   * Semgrep_error_code.exn_to_error to generate a PatternParseError instead
   * of a RuleParseError *)
  | InvalidPattern (pattern, xlang, message, _yaml_path) ->
      spf
        "Invalid pattern for %s: %s\n\
         ----- pattern -----\n\
         %s\n\
         ----- end pattern -----\n"
        (Xlang.to_string xlang) message pattern
  | MissingPositiveTermInAnd ->
      "you need at least one positive term (not just negations or conditions)"
  | DeprecatedFeature s -> spf "deprecated feature: %s" s
  | IncompatibleRule (cur, (Some min_version, None)) ->
      spf "This rule requires upgrading Semgrep from version %s to at least %s"
        (Version_info.to_string cur)
        (Version_info.to_string min_version)
  | IncompatibleRule (cur, (None, Some max_version)) ->
      spf
        "This rule is no longer supported by Semgrep. The last compatible \
         version was %s. This version of Semgrep is %s"
        (Version_info.to_string max_version)
        (Version_info.to_string cur)
  | IncompatibleRule (cur, (Some min_version, Some max_version)) ->
      spf
        "This rule requires a version of Semgrep within [%s, %s] but we're \
         using version %s"
        (Version_info.to_string min_version)
        (Version_info.to_string max_version)
        (Version_info.to_string cur)
  | IncompatibleRule (_, (None, None)) -> assert false
  | MissingPlugin msg -> msg
  | InvalidOther s -> s

let string_of_invalid_rule_error ((kind, rule_id, pos) : invalid_rule_error) =
  spf "invalid rule %s, %s: %s"
    (rule_id :> string)
    (Tok.stringpos_of_tok pos)
    (string_of_invalid_rule_error_kind kind)

let string_of_error (error : error) : string =
  match error.kind with
  | InvalidRule x -> string_of_invalid_rule_error x
  | InvalidYaml (msg, pos) ->
      spf "invalid YAML, %s: %s" (Tok.stringpos_of_tok pos) msg
  | DuplicateYamlKey (key, pos) ->
      spf "invalid YAML, %s: duplicate key %S" (Tok.stringpos_of_tok pos) key
  | UnparsableYamlException s ->
      (* TODO: what's the string s? *)
      spf "unparsable YAML: %s" s

(*
   Exception printers for Printexc.to_string.
*)
let opt_string_of_exn (exn : exn) =
  match exn with
  | Error x -> Some (string_of_error x)
  | _ -> None

let () = Printexc.register_printer opt_string_of_exn

(*****************************************************************************)
(* Visitor/extractor *)
(*****************************************************************************)
(* currently used in Check_rule.ml metachecker *)
(* OK, this is only a little disgusting, but...
   Evaluation order means that we will only visit children after parents.
   So we keep a reference cell around, and set it to true whenever we descend
   under an inside.
   That way, pattern leaves underneath an Inside will properly be paired with
   a true boolean.
*)
let visit_new_formula f formula =
  let bref = ref false in
  let rec visit_new_formula f formula =
    match formula with
    | P p -> f p !bref
    | Inside (_, formula) ->
        Common.save_excursion bref true (fun () -> visit_new_formula f formula)
    | Not (_, x) -> visit_new_formula f x
    | Or (_, xs)
    | And (_, { conjuncts = xs; _ }) ->
        xs |> List.iter (visit_new_formula f)
  in
  visit_new_formula f formula

(* used by the metachecker for precise error location *)
let tok_of_formula = function
  | And (t, _) -> t
  | Or (t, _)
  | Not (t, _) ->
      t
  | P p -> snd p.pstr
  | Inside (t, _) -> t

let kind_of_formula = function
  | P _ -> "pattern"
  | Or _
  | And _
  | Inside _
  | Not _ ->
      "formula"

let rec formula_of_mode (mode : mode) =
  match mode with
  | `Search formula -> [ formula ]
  | `Taint { sources = _, sources; sanitizers; sinks = _, sinks; propagators }
    ->
      Common.map (fun src -> src.source_formula) sources
      @ (match sanitizers with
        | None -> []
        | Some (_, sanitizers) ->
            Common.map (fun sanitizer -> sanitizer.sanitizer_formula) sanitizers)
      @ Common.map (fun sink -> sink.sink_formula) sinks
      @ Common.map (fun prop -> prop.propagator_formula) propagators
  | `Extract { formula; extract = _; _ } -> [ formula ]
  | `Secrets { secrets; _ } -> secrets
  | `Steps steps ->
      List.concat_map
        (fun step -> formula_of_mode (step.step_mode :> mode))
        steps

let xpatterns_of_rule rule =
  let formulae = formula_of_mode rule.mode in
  let xpat_store = ref [] in
  let visit xpat _ = xpat_store := xpat :: !xpat_store in
  List.iter (visit_new_formula visit) formulae;
  !xpat_store

(*****************************************************************************)
(* Converters *)
(*****************************************************************************)

let languages_of_lang (lang : Lang.t) : languages =
  { target_selector = Some [ lang ]; target_analyzer = L (lang, []) }

let languages_of_xlang (xlang : Xlang.t) : languages =
  match xlang with
  | LRegex
  | LAliengrep
  | LSpacegrep ->
      { target_selector = None; target_analyzer = xlang }
  | L (lang, other_langs) ->
      { target_selector = Some (lang :: other_langs); target_analyzer = xlang }

(* return list of "positive" x list of Not *)
let split_and (xs : formula list) : formula list * (tok * formula) list =
  xs
  |> Common.partition_either (fun e ->
         match e with
         (* positives *)
         | P _
         | And _
         | Inside _
         | Or _ ->
             Left e
         (* negatives *)
         | Not (tok, f) -> Right (tok, f))

(* create a fake rule when we only have a pattern and language.
 * This is used when someone calls `semgrep -e print -l python`
 *)
let rule_of_xpattern (xlang : Xlang.t) (xpat : Xpattern.t) : rule =
  let fk = Tok.unsafe_fake_tok "" in
  {
    id = (Rule_ID.of_string "-e", fk);
    mode = `Search (P xpat);
    min_version = None;
    max_version = None;
    (* alt: could put xpat.pstr for the message *)
    message = "";
    severity = Error;
    languages = languages_of_xlang xlang;
    options = None;
    equivalences = None;
    fix = None;
    fix_regexp = None;
    paths = None;
    metadata = None;
  }

(* TODO(dinosaure): Currently, on the Python side, we remove the metadatas and
   serialise the rule into JSON format, then produce the hash from this
   serialisation. However, there is no way (yet?) to serialise OCaml [Rule.t]s
   into JSON format. It exists, however, a path where we should be able to
   serialize a [Rule.t] via [ppx] (or by hands). It requires more work because
   we must have a way to serialize all types required by [Rule.t] but the
   propagation of a [ppx] such as [ppx_deriving.show] demonstrates that it's
   possible to implement such function.

   Actually, we tried to use [Marshal] and produce a hash from the /marshalled/
   output but [Rule.t] contains some custom blocks that the [Marshal] module can
   not handle.

   Currently, we did the choice to **only** hash the [ID.t] of the given rule
   which is clearly not enough comparing to the Python code. But, again, we can
   improve that by serialize everything and compute a hash from it. *)
let sha256_of_rule rule =
  Digestif.SHA256.digest_string (Rule_ID.to_string (fst rule.id))
