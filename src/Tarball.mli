
type t
(** A handle to the tarball that we can use to query for further
    information. *)

val get : string -> t
(** Get the tarball corresponding to an URL (http or https) or a local
    file. *)

val md5 : t -> string
(** Return the MD5 hash of the tarball. *)

val url : t -> string
(** Returns the URL of the package or [""] if it was a local file (and
    thus cannot be used in the "url" file for OPAM. *)

val oasis : t -> OASISTypes.package
(** Return the content of the _oasis file.  A fatal error is issued if
    the tarball does not contain an _oasis file. *)

val needs_oasis : t -> bool
(** Whether oasis is required to compile, either because there is no
    setup.ml file or because dynamic mode is used. *)

val setup_ml_exists : t -> bool
(** Whether a file "setup.ml" exists in the tarball. *)

val opam : t -> string
(** Return the content of the _opam file in the tarball (or [""] if
    no such file exists). *)


;;
