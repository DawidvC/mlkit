(*************************************************************)
(* Grammar for Bare language - Definition v3 pages 8,9,70,71 *)
(* modified to have ident in place of con  var and excon     *)
(*************************************************************)

(*$DEC_GRAMMAR : LAB SCON TYVAR TYCON STRID IDENT*)

signature DEC_GRAMMAR =
sig
  structure Lab   : LAB   (* labels *)
  structure SCon  : SCON  (* special constants *)                            
  structure Ident : IDENT (* identifiers - variables or constructors *)      
  structure TyVar : TYVAR (* type variables *)                               
  structure TyCon : TYCON (* type constructors *)                            
  structure StrId : STRID (* structure identifiers *)
                 sharing type StrId.strid = Ident.strid = TyCon.strid

  type lab       sharing type lab = Lab.lab
  type scon      sharing type scon = SCon.scon
  type id        sharing type id = Ident.id
  type longid    sharing type longid = Ident.longid
  eqtype tyvar   sharing type tyvar = TyVar.SyntaxTyVar (*inkonsekvent & meget forvirrende*)
  type   tycon   sharing type tycon = TyCon.tycon
  type longtycon sharing type longtycon = TyCon.longtycon
  type longstrid sharing type longstrid = StrId.longstrid

  type info       (* info about the position in the source text, errors etc *)
  val bogus_info : info

  datatype 'a op_opt = OP_OPT of 'a * bool
  datatype 'a WithInfo = WITH_INFO of info * 'a
  val strip_info : 'a WithInfo -> 'a

  datatype atexp =
	SCONatexp of info * scon |         
	IDENTatexp of info * longid op_opt |
	RECORDatexp of info * exprow Option |
	LETatexp of info * dec * exp |
	PARatexp of info * exp

  and exprow =
	EXPROW of info * lab * exp * exprow Option

  and exp =
	ATEXPexp of info * atexp |
	APPexp of info * exp * atexp |
	TYPEDexp of info * exp * ty |
	HANDLEexp of info * exp * match |
	RAISEexp of info * exp |
	FNexp of info * match |
	UNRES_INFIXexp of info * atexp list
      
  and match =
        MATCH of info * mrule * match Option

  and mrule =
        MRULE of info * pat * exp

  and dec = 
	VALdec of info * tyvar list * valbind |
	UNRES_FUNdec of info * tyvar list * FValBind |
		(* TEMPORARY: removed when resolving infixes after parsing. *)
	TYPEdec of info * typbind |
	DATATYPEdec of info * datbind |
	DATATYPE_REPLICATIONdec of info * tycon * longtycon |
	ABSTYPEdec of info * datbind * dec |
	EXCEPTIONdec of info * exbind |
	LOCALdec of info * dec * dec |
	OPENdec of info * longstrid WithInfo list |
	SEQdec of info * dec * dec |
	INFIXdec of info * int Option * id list |
	INFIXRdec of info * int Option * id list |
	NONFIXdec of info * id list |
	EMPTYdec of info

  and valbind =
	PLAINvalbind of info * pat * exp * valbind Option |
	RECvalbind of info * valbind

  and FValBind = FVALBIND of info * FClause * FValBind Option
  and FClause = FCLAUSE of info * atpat list * ty Option * exp * FClause Option

  and typbind =
        TYPBIND of info * tyvar list * tycon * ty * typbind Option

  and datbind =
        DATBIND of info * tyvar list * tycon * conbind * datbind Option

  and conbind =
        CONBIND of info * id op_opt * ty Option * conbind Option

  and exbind =
        EXBIND of info * id op_opt * ty Option * exbind Option |
        EXEQUAL of info * id op_opt * longid op_opt * exbind Option

  and atpat =
        WILDCARDatpat of info |
	SCONatpat of info * scon |
	LONGIDatpat of info * longid op_opt |
	RECORDatpat of info * patrow Option |
	PARatpat of info * pat

  and patrow =
        DOTDOTDOT of info |
        PATROW of info * lab * pat * patrow Option

  and pat =
        ATPATpat of info * atpat |
        CONSpat of info * longid op_opt * atpat |
        TYPEDpat of info * pat * ty |
        LAYEREDpat of info * id op_opt * ty Option * pat |
	UNRES_INFIXpat of info * atpat list

  and ty =
        TYVARty of info * tyvar |
        RECORDty of info * tyrow Option |
        CONty of info * ty list * longtycon |
        FNty of info * ty * ty |
        PARty of info * ty

  and tyrow =
        TYROW of info * lab * ty * tyrow Option

  val get_info_atexp : atexp -> info
  val get_info_exprow : exprow -> info
  val get_info_exp : exp -> info
  val get_info_match : match -> info
  val get_info_mrule : mrule -> info
  val get_info_dec : dec -> info
  val get_info_valbind : valbind -> info
  val get_info_datbind : datbind -> info
  val get_info_conbind : conbind -> info
  val get_info_pat : pat -> info
  val get_info_atpat : atpat -> info
  val get_info_patrow : patrow -> info
  val get_info_ty : ty -> info
  val get_info_typbind : typbind -> info
  val get_info_tyrow : tyrow -> info
  val get_info_exbind : exbind -> info
  val get_info_FValBind : FValBind -> info
  val get_info_FClause : FClause -> info

  val map_atexp_info : (info -> info) -> atexp -> atexp
  val map_exprow_info : (info -> info) -> exprow -> exprow
  val map_exp_info : (info -> info) -> exp -> exp
  val map_match_info : (info -> info) -> match -> match
  val map_mrule_info : (info -> info) -> mrule -> mrule
  val map_dec_info : (info -> info) -> dec -> dec
  val map_valbind_info : (info -> info) -> valbind -> valbind
  val map_datbind_info : (info -> info) -> datbind -> datbind
  val map_conbind_info : (info -> info) -> conbind -> conbind
  val map_pat_info : (info -> info) -> pat -> pat
  val map_atpat_info : (info -> info) -> atpat -> atpat
  val map_patrow_info : (info -> info) -> patrow -> patrow
  val map_ty_info : (info -> info) -> ty -> ty


  val getExplicitTyVarsTy      : ty -> tyvar list
  and getExplicitTyVarsConbind : conbind -> tyvar list

  (*expansive harmless_con exp = true iff exp is expansive.
   harmless_con longid = true iff longid is an excon or a con different
   from id_REF.  To know this, the context is necessary; that is the
   reason you must provide harmless_con.*)

  val expansive : (longid -> bool) -> exp -> bool

  val find_topmost_id_in_pat : pat -> string Option
  val find_topmost_id_in_atpat: atpat -> string Option

  (*is_'true'_'nil'_etc & is_'it' are used to enforce some syntactic
   restrictions (Definition, �2.9 & �3.5).*)

  val is_'true'_'nil'_etc : id -> bool
  val is_'it' : id -> bool

  type StringTree

  val layoutTyvarseq : tyvar list -> StringTree Option
  val layoutTy :       ty	  -> StringTree
  val layoutAtpat :    atpat	  -> StringTree
  val layoutPat :      pat	  -> StringTree
  val layoutExp :      exp	  -> StringTree
  val layoutDec :      dec	  -> StringTree
  val layout_datatype_replication : info * tycon * longtycon -> StringTree
end;
