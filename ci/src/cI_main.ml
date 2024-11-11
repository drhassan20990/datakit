open Datakit_github

let key_bits = 4096

open CI_utils
open! Astring
open Lwt.Infix

let logs = CI_live_log.create_manager ()

let connect protocol address =
  (* Connect to 9p server *)
  Log.info (fun f ->
      f "Connecting to DataKit server on %s:%s" protocol address);
  Lwt.catch
    (fun () ->
      Client9p.connect protocol address ~send_pings:true
        ~max_fids:Int32.max_int ()
      >|= function
      | Ok x -> x
      | Error (`Msg m) -> failwith m)
    (fun ex ->
      failf "Failed to connect to DataKit server at proto=%S addr=%S: %s"
        protocol address (Printexc.to_string ex))

let make_session_backend = function
  | `Memory -> `Memory
  | `Redis addr ->
      (* Can't see a way to check whether a connection is still valid, so
       just throw away any connection that fails.
       See: https://github.com/0xffea/ocaml-redis/issues/44 *)
      let check _ set_valid = set_valid false in
      let connect () =
        Lwt.catch
          (fun () -> Redis_lwt.Client.connect addr)
          (fun ex ->
            Log.warn (fun f ->
                let { Redis_lwt.Client.host; port } = addr in
                f "Error connecting to Redis database at %s:%d: %a" host port
                  CI_utils.pp_exn ex);
            Lwt.fail ex)
      in
      `Redis (Lwt_pool.create 4 ~check connect)

let start_lwt ~pr_store ~web_ui ~secrets_dir ~canaries ~config ~session_backend
    ~prometheus =
  let prometheus_threads = Prometheus_unix.serve prometheus in
  let { CI_config.web_config; projects } = config in
  let dashboards = Repo.Map.map (fun p -> p.CI_config.dashboards) projects in
  let projects = Repo.Map.map (fun p -> p.CI_config.tests) projects in
  CI_secrets.create ~key_bits secrets_dir >>= fun secrets ->
  CI_secrets.github_auth secrets >>= fun github ->
  let github_scopes_needed =
    web_config.CI_web_templates.github_scopes_needed
  in
  let passwd_path = CI_secrets.passwords_path secrets in
  CI_web_utils.Auth.create ~github ~github_scopes_needed ~web_ui passwd_path
  >>= fun auth ->
  let proto, addr = pr_store in
  let connect_dk () = connect proto addr >|= DK.connect in
  let canaries =
    match canaries with
    | [] -> None
    | canaries -> Some (CI_target.map_of_list canaries)
  in
  let ci = CI_engine.create ~web_ui ?canaries connect_dk projects in
  let main_thread =
    CI_engine.listen ci >|= fun `Abort ->
    assert false
  in
  let mode =
    match web_config.CI_web_templates.listen_addr with
    | `HTTP port -> `TCP (`Port port)
    | `HTTPS port ->
        `TLS
          ( `Crt_file_path (CI_secrets.certificate_path secrets),
            `Key_file_path (CI_secrets.private_key_path secrets),
            `No_password,
            `Port port )
  in
  let session_backend = make_session_backend session_backend in
  let server =
    CI_web_utils.server ~web_config ~auth ~session_backend
      ~public_address:web_ui
  in
  let routes = CI_web.routes ~server ~logs ~ci ~dashboards in
  Lwt.pick
    (main_thread :: CI_web_utils.serve ~routes ~mode :: prometheus_threads)

let start () pr_store web_ui secrets_dir config canaries session_backend
    prometheus =
  let secrets_dir = CI_utils.abs_path secrets_dir in
  if Logs.Src.level src < Some Logs.Info then
    Logs.Src.set_level src (Some Logs.Info);
  try
    Lwt_main.run
      (start_lwt ~pr_store ~web_ui ~secrets_dir ~canaries ~config
         ~session_backend ~prometheus)
  with Failure msg ->
    Fmt.epr "Failure:@,%s@." msg;
    exit 1

(* Command-line parsing *)

open Cmdliner

let pr_store =
  let doc =
    Arg.info ~doc:"DataKit store for metadata." ~docv:"ADDR"
      [ "metadata-store" ]
  in
  Arg.(value (opt (pair ~sep:':' string string) ("tcp", "localhost:5640") doc))

let secrets_dir =
  let doc =
    Arg.info ~doc:"Directory to store crypto secrets." ~docv:"DIR"
      [ "secrets-dir" ]
  in
  Arg.(value (opt Arg.dir "/secrets" doc))

let uri =
  let parse s =
    try `Ok (Uri.of_string s) with ex -> `Error (Printexc.to_string ex)
  in
  (parse, Uri.pp_hum)

let web_ui =
  let doc =
    Arg.info ~doc:"URL of main web page (for GitHub status URLs)" ~docv:"URL"
      [ "web-ui" ]
  in
  Arg.(value (opt uri (Uri.of_string "https://127.0.0.1:8443/") doc))

let canaries =
  let doc =
    Arg.info ~doc:"Only test these refs (e.g user/project/heads/master)"
      ~docv:"TARGET" [ "canary" ]
  in
  Arg.(value (opt_all CI_target.arg [] doc))

let session_backend =
  let parse s =
    let uri = Uri.of_string s in
    match Uri.scheme uri with
    | Some "memory" -> `Ok `Memory
    | Some "redis" ->
        let host = Uri.host uri |> CI_utils.default "127.0.0.1" in
        let port = Uri.port uri |> CI_utils.default 6379 in
        `Ok (`Redis { Redis_lwt.Client.host; port })
    | _ -> `Error (Fmt.strf "Bad scheme in %a" Uri.pp_hum uri)
  in
  let print f = function
    | `Memory -> Fmt.pf f "memory://"
    | `Redis { Redis_lwt.Client.host; port } ->
        let uri = Uri.make ~scheme:"redis" ~host ~port () in
        Uri.pp_hum f uri
  in
  let mk = (parse, print) in
  let doc =
    Arg.info ~doc:"Where to store web UI session data (e.g. redis://host:port)"
      ~docv:"URL" [ "sessions-backend" ]
  in
  Arg.(value (opt mk `Memory doc))

let default_info = Term.info "DataKitCI"

let run ?(info = default_info) config =
  let spec =
    Term.(
      const start $ CI_log_reporter.setup_log $ pr_store $ web_ui $ secrets_dir
      $ config $ canaries $ session_backend $ Prometheus_unix.opts)
  in
  match Term.eval (spec, info) with
  | `Error _ -> exit 1
  | _ -> exit (if Logs.err_count () > 0 then 1 else 0)
