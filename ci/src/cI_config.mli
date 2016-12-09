open Datakit_github
open Astring

type test = string CI_term.t

type project = {
  dashboards : CI_target.ID_Set.t;
  tests : CI_target.Full.t -> test String.Map.t;
}

type t = private {
  web_config : CI_web_templates.t;
  projects : project Repo.Map.t;
}

val project : id:string -> ?dashboards:string list -> (CI_target.Full.t -> (string * test) list) -> Repo.t * project

val ci :
  web_config:CI_web_templates.t ->
  projects:(Repo.t * project) list ->
  t
