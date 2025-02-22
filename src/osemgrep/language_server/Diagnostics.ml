open Lsp
open Types
module Conv = Convert_utils
module Out = Semgrep_output_v1_t

let diagnostic_of_match (m : Out.cli_match) =
  let severity = Conv.severity_of_string m.extra.severity in
  let message = m.extra.message in
  let code = `String m.check_id in
  let shortlink =
    let metadata = (m.extra.metadata :> Yojson.Safe.t) in
    match metadata with
    | `Assoc _ ->
        metadata
        |> Yojson.Safe.Util.member "shortlink"
        |> Yojson.Safe.Util.to_string_option
    | _ -> None
  in
  let codeDescription =
    Option.bind shortlink (fun s ->
        Some (CodeDescription.create ~href:(Uri.t_of_yojson (`String s))))
  in
  let diagnostic =
    Diagnostic.create
      ~range:(Conv.range_of_cli_match m)
      ~code ~severity ~source:"Semgrep" ~message
  in
  match codeDescription with
  | None -> diagnostic ()
  | Some codeDescription -> diagnostic ~codeDescription ()

let diagnostics_of_file matches file =
  let matches =
    List.filter (fun (m : Out.cli_match) -> Fpath.v m.path = file) matches
  in
  let diagnostics = Common.map diagnostic_of_match matches in
  let ranges_overlap (a : Diagnostic.t) (b : Diagnostic.t) =
    if a.range.start.line = b.range.start.line then
      a.range.start.character <= b.range.start.character
    else
      a.range.start.line <= b.range.start.line
      && a.range.end_.line >= b.range.end_.line
  in
  let diagnostics =
    Common.uniq_by
      (fun (a : Diagnostic.t) (b : Diagnostic.t) ->
        a.code = b.code && ranges_overlap a b)
      diagnostics
  in
  let params =
    PublishDiagnosticsParams.create
      ~uri:(Uri.of_path (Fpath.to_string file))
      ~diagnostics ()
  in
  Server_notification.PublishDiagnostics params

let diagnostics_of_results results files =
  Common.map (diagnostics_of_file results) files
