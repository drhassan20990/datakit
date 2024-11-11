open Astring

module Metrics = struct
  open Prometheus

  let namespace = "DataKitCI"

  let subsystem = "pool"

  let qlen =
    let help = "Number of users waiting for a resource" in
    Gauge.v_label ~help ~label_name:"name" ~namespace ~subsystem "qlen"

  let wait_time =
    let help = "Time spent waiting for a resource" in
    Summary.v_label ~help ~label_name:"name" ~namespace ~subsystem
      "wait_time_seconds"

  let use_time =
    let help = "Time spent using a resource" in
    Summary.v_label ~help ~label_name:"name" ~namespace ~subsystem
      "use_time_seconds"

  let resources_in_use =
    let help = "Number of resources currently being used" in
    Gauge.v_label ~help ~label_name:"name" ~namespace ~subsystem
      "resources_in_use"

  let capacity =
    let help = "Total pool capacity" in
    Gauge.v_label ~help ~label_name:"name" ~namespace ~subsystem "capacity"
end

type t = {
  label : string;
  capacity : int;
  mutable qlen : int;
  mutable active : int;
  pool : unit Lwt_pool.t;
  mutable users : ((CI_s.job_id * string option) * CI_live_log.t option) list;
}

let registered_pools = ref String.Map.empty

let create label capacity =
  let pool = Lwt_pool.create capacity Lwt.return in
  let t = { label; capacity; qlen = 0; active = 0; pool; users = [] } in
  assert (not (String.Map.mem label !registered_pools));
  registered_pools := String.Map.add label t !registered_pools;
  Prometheus.Gauge.set (Metrics.capacity label) (float_of_int capacity);
  t

let rec remove_first msg = function
  | [] -> assert false
  | (m, _) :: xs when m = msg -> xs
  | x :: xs -> x :: remove_first msg xs

let use ?log t ~reason fn =
  let qlen = Metrics.qlen t.label in
  Prometheus.Gauge.inc_one qlen;
  t.qlen <- t.qlen + 1;
  let dec =
    lazy
      ( Prometheus.Gauge.dec_one qlen;
        t.qlen <- t.qlen - 1 )
  in
  let start_wait = Unix.gettimeofday () in
  Lwt.finalize
    (fun () ->
      Lwt_pool.use t.pool (fun v ->
          Lazy.force dec;
          let stop_wait = Unix.gettimeofday () in
          Prometheus.Summary.observe
            (Metrics.wait_time t.label)
            (stop_wait -. start_wait);
          t.active <- t.active + 1;
          t.users <- (reason, log) :: t.users;
          Prometheus.Gauge.track_inprogress (Metrics.resources_in_use t.label)
          @@ fun () ->
          Lwt.finalize
            (fun () -> fn v)
            (fun () ->
              let stop_use = Unix.gettimeofday () in
              Prometheus.Summary.observe (Metrics.use_time t.label)
                (stop_use -. stop_wait);
              t.active <- t.active - 1;
              t.users <- remove_first reason t.users;
              Lwt.return_unit)))
    (fun () ->
      Lazy.force dec;
      Lwt.return ())

let use t ?log ?label job_id fn =
  let reason = (job_id, label) in
  match log with
  | None -> use ?log t ~reason fn
  | Some log ->
      let msg = Fmt.strf "Waiting for resource in %S" t.label in
      CI_live_log.enter_with_pending_reason log msg (use ~log t ~reason) fn

let active t = t.active

let capacity t = t.capacity

let qlen t = t.qlen

let pools () = !registered_pools

let users t = t.users
