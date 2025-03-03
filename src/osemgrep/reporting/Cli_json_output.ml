open Common
module Out = Semgrep_output_v1_j

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Convert results coming from Core_runner (semgrep-core JSON output)
 * to the formally specified Semgrep CLI JSON output.
 *
 * I'm skipping lots of Python code and lots of intermediate modules for now
 * and just go directly from the Core_runner results to the final Cli_output.
 * In the Python codebase it goes through many intermediate data-structures
 * (e.g., RuleMatchMap, SemgrepCoreError, FileTargetingLog, ProfilingData)
 * and many modules:
 *  - scan.py
 *  - semgrep_main.py
 *  - core_runner.py
 *  - core_output.py
 *  - error.py
 *  - output.py
 *  - formatter/base.py
 *  - formatter/json.py
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* LATER: use Metavariable.bindings directly ! *)
type metavars = (string * Out.metavar_value) list

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* Substitute the metavariables mentioned in a message to their
 * matched content.
 *
 * We could either:
 *  (1) go through all the metavars and textually substitute them in the text
 *  (2) go through the text and find each metavariable regexp occurence
 *    and replace them with their content
 * python: the original code did (1) so we're doing the same for now,
 * however (2) seems more logical to me and wasting less CPUs since
 * you only substitute metavars that are actually mentioned in the message.
 *
 * TODO: expose this function so it can be used in language_server
 *)
let interpolate_metavars (text : string) (metavars : metavars) (file : filename)
    : string =
  (* sort by metavariable length to avoid name collisions
   * (eg. $X2 must be handled before $X)
   *)
  let mvars =
    metavars
    |> List.sort (fun (a, _) (b, _) ->
           compare (String.length b) (String.length a))
  in
  mvars
  |> List.fold_left
       (fun text (mvar, mval) ->
         (* necessary typing to help the type check disambiguate fields,
          * because of the use of multiple fields with the same
          * name in semgrep_output_v1.atd *)
         let (v : Out.metavar_value) = mval in
         let content =
           lazy
             (Output_utils.content_of_file_at_range (v.start, v.end_)
                (Fpath.v file))
         in
         text
         (* first value($X), and then $X *)
         |> Str.global_substitute
              (Str.regexp_string (spf "value(%s)" mvar))
              (fun _whole_str ->
                match v.propagated_value with
                | Some x ->
                    x.svalue_abstract_content (* default to the matched value *)
                | None -> Lazy.force content)
         |> Str.global_substitute (Str.regexp_string mvar) (fun _whole_str ->
                Lazy.force content))
       text

(* TODO: expose this function so it can be used in language_server *)
let render_fix (hrules : Rule.hrules) (x : Out.core_match) : string option =
  match x with
  | { check_id = rule_id; path; extra = { metavars; rendered_fix; _ }; _ } -> (
      let rule =
        try Hashtbl.find hrules (Rule_ID.of_string rule_id) with
        | Not_found -> raise Impossible
      in
      (* TOPORT: debug logging which indicates the source of the fix *)
      match (rendered_fix, rule.fix) with
      | Some fix, _ -> Some fix
      | None, Some fix -> Some (interpolate_metavars fix metavars path)
      | None, None -> None)

(*****************************************************************************)
(* Core error to cli error *)
(*****************************************************************************)
(* LATER: we should get rid of those intermediate Out.core_xxx *)

let core_location_to_error_span (loc : Out.location) : Out.error_span =
  {
    file = loc.path;
    start = loc.start;
    end_ = loc.end_;
    source_hash = None;
    config_start = None;
    config_end = None;
    config_path = None;
    context_start = None;
    context_end = None;
  }

(* LATER: move to Severity.ml, and use Severity.rule_severity instead? *)
let string_of_severity (severity : Rule.severity) : string =
  match severity with
  | Error -> "ERROR"
  | Warning -> "WARNING"
  | Info -> "INFO"
  | Experiment -> "EXPERIMENT"
  | Inventory -> "INVENTORY"

(* LATER: move also to Severity.ml and reuse types there *)
let level_of_severity (severity : Out.core_severity) : Severity.t =
  match severity with
  | Error -> `Error
  | Warning -> `Warning
  | Info -> `Info

let error_type_string (error_type : Out.core_error_kind) : string =
  match error_type with
  (* # convert to the same string of core.ParseError for now *)
  | PartialParsing _ -> "Syntax error"
  | PatternParseError _ -> "Pattern parse error"
  (* # All the other cases don't have arguments in Semgrep_output_v1.atd
   * # and have some <json name="..."> annotations to generate the right string
   * python: str(type_.to_json())
   * but safer to just enumerate and write the boilerplate in OCaml
   *)
  | LexicalError -> "Lexical error"
  | ParseError -> "Syntax error"
  | SpecifiedParseError -> "Other syntax error"
  | AstBuilderError -> "AST builder error"
  | RuleParseError -> "Rule parse error"
  | InvalidYaml -> "Invalid YAML"
  | MatchingError -> "Internal matching error"
  | SemgrepMatchFound -> "Semgrep match found"
  | TooManyMatches -> "Too many matches"
  | FatalError -> "Fatal error"
  | Timeout -> "Timeout"
  | OutOfMemory -> "Out of memory"
  | TimeoutDuringInterfile -> "Timeout during interfile analysis"
  | OutOfMemoryDuringInterfile -> "OOM during interfile analysis"
  | IncompatibleRule _ -> "Incompatible rule"
  | MissingPlugin -> "Missing plugin"

(* Generate error message exposed to user *)
let error_message ~rule_id ~(location : Out.location)
    ~(error_type : Out.core_error_kind) ~core_message : string =
  let path = location.path in
  let error_context =
    match (rule_id, error_type) with
    (* For rule errors, the path is a temporary JSON file containing
       the broken rule(s). *)
    | Some id, (RuleParseError | PatternParseError _) -> spf "in rule %s" id
    | ( Some id,
        ( PartialParsing _ | ParseError | SpecifiedParseError | AstBuilderError
        | InvalidYaml | MatchingError | SemgrepMatchFound | TooManyMatches
        | FatalError | Timeout | OutOfMemory | TimeoutDuringInterfile
        | OutOfMemoryDuringInterfile ) ) ->
        spf "when running %s on %s" id path
    | Some id, IncompatibleRule _ -> id
    | Some id, MissingPlugin -> spf "for rule %s" id
    | _ -> spf "at line %s:%d" path location.start.line
  in
  spf "%s %s:\n %s" (error_type_string error_type) error_context core_message

let error_spans ~(error_type : Out.core_error_kind) ~(location : Out.location) =
  match error_type with
  | PatternParseError _yaml_pathTODO ->
      (* TOPORT
         yaml_path = err.error_type.value.value[::-1]
         spans = [dataclasses.replace(..., config_path=yaml_path)]
      *)
      let span =
        (* This code matches the Python code.
           Not sure what it does, frankly. *)
        {
          (core_location_to_error_span location) with
          config_start = Some (Some { line = 0; col = 1; offset = -1 });
          config_end =
            Some
              (Some
                 {
                   line = location.end_.line - location.start.line;
                   col = location.end_.col - location.start.col + 1;
                   offset = -1;
                 });
        }
      in
      Some [ span ]
  | PartialParsing locs -> Some (locs |> Common.map core_location_to_error_span)
  | _else_ -> None

(* # TODO benchmarking code relies on error code value right now
   * # See https://semgrep.dev/docs/cli-usage/ for meaning of codes
*)
let exit_code_of_error_type (error_type : Out.core_error_kind) : Exit_code.t =
  match error_type with
  | ParseError
  | LexicalError
  | PartialParsing _ ->
      Exit_code.invalid_code
  | SpecifiedParseError
  | AstBuilderError
  | RuleParseError
  | PatternParseError _
  | InvalidYaml
  | MatchingError
  | SemgrepMatchFound
  | TooManyMatches
  | FatalError
  | Timeout
  | OutOfMemory
  | TimeoutDuringInterfile
  | OutOfMemoryDuringInterfile ->
      Exit_code.fatal
  | IncompatibleRule _
  | MissingPlugin ->
      Exit_code.ok

(* Skipping the intermediate python SemgrepCoreError for now.
 * TODO: should we return an Error.Semgrep_core_error instead? like we
 * do in python? and then generate an Out.cli_error out of it?
 *)
let cli_error_of_core_error (x : Out.core_error) : Out.cli_error =
  match x with
  | {
   error_type;
   severity;
   location;
   message = core_message;
   rule_id;
   (* LATER *) details = _;
  } ->
      let level = level_of_severity severity in
      let exit_code = exit_code_of_error_type error_type in
      let rule_id =
        match error_type with
        (* # Rule id not important for parse errors *)
        | ParseError
        | LexicalError
        | PartialParsing _ ->
            None
        | _else_ -> rule_id
      in
      let path =
        (* # For rule errors path is a temp file so will just be confusing *)
        match error_type with
        | RuleParseError
        | PatternParseError _ ->
            None
        | _else_ -> Some location.path
      in
      let message =
        Some (error_message ~rule_id ~error_type ~location ~core_message)
      in
      let spans = error_spans ~error_type ~location in
      {
        (* LATER? seems to be either 2 (fatal) or 3 (invalid_code), so maybe
         * better to change the ATD spec and use a variant for cli_error.code
         *)
        code = Exit_code.to_int exit_code;
        (* LATER: should use a variant too *)
        level = Severity.to_string level;
        (* LATER: type_ should be a proper variant instead of a string *)
        type_ = error_type_string error_type;
        rule_id;
        path;
        message;
        spans;
        (* LATER *)
        long_msg = None;
        short_msg = None;
        help = None;
      }

(*****************************************************************************)
(* Core match to cli match *)
(*****************************************************************************)
(* LATER: we should get rid of those intermediate Out.core_xxx *)

let cli_match_of_core_match (hrules : Rule.hrules) (m : Out.core_match) :
    Out.cli_match =
  match m with
  | {
   check_id = rule_id;
   path;
   start;
   end_;
   extra =
     {
       message;
       metavars;
       engine_kind;
       extra_extra;
       validation_state;
       (* used now in render_fix instead *)
       rendered_fix = _;
       (* LATER *)
       dataflow_trace = _;
     };
  } ->
      let rule =
        try Hashtbl.find hrules (Rule_ID.of_string rule_id) with
        | Not_found -> raise Impossible
      in
      let message =
        match message with
        (* message where the metavars have been interpolated *)
        | Some s -> interpolate_metavars s metavars path
        | None -> ""
      in
      let fix = render_fix hrules m in
      let check_id = rule_id in
      let metavars = Some metavars in
      (* LATER: this should be a variant in semgrep_output_v1.atd
       * and merged with Constants.rule_severity
       *)
      let severity = string_of_severity rule.severity in
      let metadata =
        match rule.metadata with
        | None -> `Assoc []
        | Some json -> JSON.to_yojson json
      in
      (* TODO? at this point why not using content_of_file_at_range since
       * we concatenate the lines after? *)
      let lines =
        Output_utils.lines_of_file_at_range (start, end_) (Fpath.v path)
        |> String.concat "\n"
      in
      {
        check_id;
        path;
        start;
        end_;
        extra =
          {
            metavars;
            lines;
            (* fields derived from the rule (and the match) *)
            message;
            severity;
            metadata;
            fix;
            (* TODO: other fields derived from the rule *)
            fix_regex = None;
            (* TODO: extra fields *)
            is_ignored = Some false;
            (* LATER *)
            (* TODO: rule_match.match_based_id *)
            fingerprint = "0x42";
            sca_info = None;
            fixed_lines = None;
            dataflow_trace = None;
            (* It's optional in the CLI output, but not in the core match results!
             *)
            engine_kind = Some engine_kind;
            validation_state;
            extra_extra;
          };
      }

(*
 # Sort results so as to guarantee the same results across different
 # runs. Results may arrive in a different order due to parallelism
 # (-j option).
 TOPORT: return {rule: sorted(matches) for rule, matches in findings.items()}
*)
let dedup_and_sort (xs : Out.cli_match list) : Out.cli_match list =
  let seen = Hashtbl.create 101 in
  xs
  |> List.filter (fun x ->
         if Hashtbl.mem seen x then false
         else
           (* TOPORT: use rule_match.cli_unique_key to dedup (not the whole x) *)
           let key = x in
           Hashtbl.replace seen key true;
           true)

(*****************************************************************************)
(* Skipped target *)
(*****************************************************************************)

(* Skipping the python intermediate FileTargetingLog for now.
 * We used to have a cli_skipped_target and core_skipped_target type,
 * but now they are merged so this function is the identity.
 * In theory we could remove the details: and rule_id: from it
 * because they used to not be included in the final JSON output
 * (but the info was used in the text output to display skipping information).
 *)
let cli_skipped_targets ~(skipped_targets : Out.skipped_target list option) :
    Out.skipped_target list option =
  (* Still? skipped targets are coming from the FileIgnoreLog which is
   * populated from many places in the code.
   * Still? see _make_failed_to_analyze() in output.py,
   * core_failure_lines_by_file in target_manager.py
   * Still? need to sort
   *)
  skipped_targets

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

(* The 3 parameters are mostly Core_runner.result but we don't want
 * to depend on cli_scan/ from reporting/ here, hence the duplication.
 * alt: we could move Core_runner.result type in core/
 *)
let cli_output_of_core_results ~logging_level (core : Out.core_output)
    (hrules : Rule.hrules) (scanned : Fpath.t Set_.t) : Out.cli_output =
  match core with
  | {
   results = matches;
   errors;
   skipped_targets;
   skipped_rules;
   (* LATER *)
   explanations = _;
   stats = _;
   time = _;
   rules_by_engine = _;
   engine_requested = _;
  } ->
      (* TODO: not sure how it's sorted. Look at rule_match.py keys? *)
      let matches =
        matches
        |> List.sort (fun (a : Out.core_match) (b : Out.core_match) ->
               compare a.check_id b.check_id)
      in
      (* TODO: not sure how it's sorted, but Set_.elements return
       * elements in OCaml compare order (=~ lexicographic for strings)
       * python: scanned=[str(path) for path in sorted(self.all_targets)]
       *)
      let scanned = scanned |> Set_.elements |> File.Path.to_strings in
      let (paths : Out.scanned_and_skipped) =
        match logging_level with
        | Some (Logs.Info | Logs.Debug) ->
            let skipped = cli_skipped_targets ~skipped_targets in
            { scanned; _comment = None; skipped }
        | _else_ ->
            {
              scanned;
              _comment = Some "<add --verbose for a list of skipped paths>";
              skipped = None;
            }
      in
      let skipped_rules =
        (* TODO: return skipped_rules with --develop

           if maturity = Develop then
             invalid_rules
           else
        *)
        (* compatibility with pysemgrep *)
        ignore skipped_rules;
        []
      in
      {
        version = Some Version.version;
        (* Skipping the python intermediate RuleMatchMap for now.
         * TODO: handle the rule_match.cli_unique_key to dedup matches
         *)
        results =
          matches
          |> Common.map (cli_match_of_core_match hrules)
          |> dedup_and_sort;
        errors = errors |> Common.map cli_error_of_core_error;
        paths;
        skipped_rules;
        (* LATER *)
        time = None;
        explanations = None;
        rules_by_engine = None;
        engine_requested = None;
      }
