(** Efficient conversions between in-memory snapshots and persistent
    datakit state. *)

open Datakit_github

(** Conversion between GitHub and DataKit states. *)
module Make (DK : Datakit_client.S) : sig
  type tree = DK.Tree.t
  (** The type for trees. *)

  (** {1 Repositories} *)

  val repos : tree -> Repo.Set.t Lwt.t
  (** [repos t] is the list of repositories stored in [t]. *)

  (** {1 Status} *)

  val statuses : ?commits:Commit.Set.t -> tree -> Status.Set.t Lwt.t
  (** [statuses t] is the list of status stored in [t]. *)

  (** {1 Pull requests} *)

  val prs : ?repos:Repo.Set.t -> tree -> PR.Set.t Lwt.t
  (** [prs t] is the list of pull requests stored in [t]. *)

  (** {1 Git References} *)

  val refs : ?repos:Repo.Set.t -> tree -> Ref.Set.t Lwt.t
  (** [refs t] is the list of Git references stored in [t].*)

  (** {1 Elements} *)

  val find : tree -> Elt.id -> Elt.t option Lwt.t
  (** [find t id] is the elements with ID [id] in [t]. *)

  val pr : tree -> PR.id -> PR.t option Lwt.t
  (** [pr t id] is the pull-request with ID [id]. *)

  val ref : tree -> Ref.id -> Ref.t option Lwt.t
  (** [ref t id] is the Git reference with ID [id]. *)

  val status : tree -> Status.id -> Status.t option Lwt.t
  (** [status t id] is the build status with ID [id]. *)

  (** {1 Updates} *)

  val update_elt : DK.Transaction.t -> Elt.t -> unit Lwt.t
  (** [update_elt t e] updates the element [e] in the transaction
      [t]. *)

  val remove_elt : DK.Transaction.t -> Elt.id -> unit Lwt.t
  (** [remove_elt t e] removes the element [e] in the transaction
      [t]. *)

  val update_event : DK.Transaction.t -> Event.t -> unit Lwt.t
  (** [update_event t e] applies the (webhook) event [e] to the
      transaction [t]. *)

  (** {1 Dirty} *)

  type dirty = Elt.IdSet.t
  (** The type for dirty elements. *)

  type t
  (** The type for filesystem snapshots. *)

  val stain : DK.Transaction.t -> dirty -> unit Lwt.t
  (** [stain tr d] makes all the elements in [d] dirty. *)

  val clean : DK.Transaction.t -> dirty -> unit Lwt.t
  (** [clean t d] removes [d] from the list of dirty elements in
      [t]. *)

  val dirty : t -> dirty
  (** [dirty t] is the collection of dirty elements in [t]. *)

  (** {1 Snapshots and diffs} *)

  val snapshot : t -> Snapshot.t
  (** [snapshot t] is [t]'s in-memory snapshot. *)

  val head : t -> DK.Commit.t
  (** [head t] is [t]'s head. *)

  val pp : t Fmt.t
  (** [pp] is the pretty-printer for {!snapshot} values. *)

  val diff : DK.Commit.t -> DK.Commit.t -> (Diff.t * dirty) Lwt.t
  (** [diff x y] computes the difference between the commits [x] and
      [y]. *)

  val of_branch :
    debug:string -> ?old:t -> DK.Branch.t -> (DK.Transaction.t * t) Lwt.t
  (** [snapshot dbg ?old b] is a pair [(t, s)] where [s] is a snapshot
      of the branch [b] and a [t] is a transaction started on [s]'s
      commit. Note: this is expensive, so try to provide a (recent)
      [old] snapshot if possible. In that case, the difference between
      the two snapshot's commits will be computed and only the minimal
      number of filesystem access will be performed to compute the new
      snapshot by updating the old one. *)

  val of_commit : debug:string -> ?old:t -> DK.Commit.t -> t Lwt.t
  (** Same as {!of_branch} but does not allow to update the underlying
      store. *)

  val apply : debug:string -> Diff.t -> DK.Transaction.t -> bool Lwt.t
  (** [apply d t] applies the snapshot diff [d] into the datakit
      transaction [t]. Returns [true] iff the undelying datakit state
      has changed. *)
end
