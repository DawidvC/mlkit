functor CodeGen(structure Con : CON
		structure Excon : EXCON
		structure Lvars : LVARS
		structure Labels : ADDRESS_LABELS
		structure CallConv: CALL_CONV
                  sharing type CallConv.lvar = Lvars.lvar
		structure LineStmt: LINE_STMT
		  sharing type Con.con = LineStmt.con
		  sharing type Excon.excon = LineStmt.excon
		  sharing type Lvars.lvar = LineStmt.lvar = CallConv.lvar
                  sharing type Labels.label = LineStmt.label
                  sharing type CallConv.cc = LineStmt.cc
	        structure SubstAndSimplify: SUBST_AND_SIMPLIFY
                  sharing type SubstAndSimplify.lvar = LineStmt.lvar
                  sharing type SubstAndSimplify.place = LineStmt.place
                  sharing type SubstAndSimplify.LinePrg = LineStmt.LinePrg
	        structure HpPaRisc : HP_PA_RISC
                  sharing type HpPaRisc.label = Labels.label
                  sharing type HpPaRisc.lvar = Lvars.lvar
	        structure BI : BACKEND_INFO
                  sharing type BI.reg = SubstAndSimplify.reg = HpPaRisc.reg
                  sharing type BI.label = Labels.label
		structure JumpTables : JUMP_TABLES
		structure HppaResolveJumps : HPPA_RESOLVE_JUMPS
		  sharing type HppaResolveJumps.AsmPrg = HpPaRisc.AsmPrg
	        structure PP : PRETTYPRINT
		  sharing type PP.StringTree = 
			       LineStmt.StringTree =
                               HpPaRisc.StringTree
		structure Flags : FLAGS
	        structure Report : REPORT
		  sharing type Report.Report = Flags.Report
		structure Crash : CRASH) : CODE_GEN =
struct

  type excon = Excon.excon
  type con = Con.con
  type lvar = Lvars.lvar
  type phsize = LineStmt.phsize
  type pp = LineStmt.pp
  type cc = CallConv.cc
  type label = Labels.label
  type ('sty,'offset,'aty) LinePrg = ('sty,'offset,'aty) LineStmt.LinePrg
  type StoreTypeCO = SubstAndSimplify.StoreTypeCO
  type AtySS = SubstAndSimplify.Aty
  type reg = HpPaRisc.reg
  type offset = int
  type AsmPrg = HpPaRisc.AsmPrg

  (***********)
  (* Logging *)
  (***********)
  fun log s = TextIO.output(!Flags.log,s ^ "\n")
  fun msg s = TextIO.output(TextIO.stdOut, s)
  fun chat(s: string) = if !Flags.chat then msg (s) else ()
  fun die s  = Crash.impossible ("CodeGen(HP-PARISC)." ^ s)
  fun fast_pr stringtree = 
    (PP.outputTree ((fn s => TextIO.output(!Flags.log, s)) , stringtree, !Flags.colwidth);
     TextIO.output(!Flags.log, "\n"))

  fun display(title, tree) =
    fast_pr(PP.NODE{start=title ^ ": ",
		    finish="",
		    indent=3,
		    children=[tree],
		    childsep=PP.NOSEP
		    })

  (****************************************************************)
  (* Add Dynamic Flags                                            *)
  (****************************************************************)
  val _ = List.app (fn (x,y,r) => Flags.add_flag_to_menu (["Printing of intermediate forms"],x,y,r))
    [("print_HP-PARISC_program", "print HP-PARISC program", ref false),
     ("debug_codeGen","DEBUG CODE_GEN",ref false)]

  (********************************)
  (* CG on Top Level Declarations *)
  (********************************)
  local
    open HpPaRisc
    structure SS = SubstAndSimplify
    structure LS = LineStmt

    (* The global accessible exception pointer label *)
    val exn_ptr_lab = NameLab "exn_ptr"
    val exn_counter_lab = NameLab "exnameCounter"

    local
      structure LibFunSet =
	OrderSet(structure Order =
		   struct
		     type T = string
		     fun lt(l1: T) l2 = l1 < l2
		   end
		 structure PP =PP
		 structure Report = Report)
      val lib_functions = ref LibFunSet.empty
    in
      fun add_lib_function str = lib_functions := LibFunSet.insert str (!lib_functions)
      fun reset_lib_functions () = lib_functions := LibFunSet.empty
      fun get_lib_functions C = 
	List.foldr (fn (str,C) => DOT_IMPORT(NameLab str, "CODE") :: C) C (LibFunSet.list (!lib_functions))
    end

    (* Labels Local To This Compilation Unit *)
    fun new_local_lab name = LocalLab (Labels.new_named name)
    local
      val counter = ref 0
      fun incr() = (counter := !counter + 1; !counter)
    in
      fun new_string_lab() : lab = DatLab(Labels.new_named ("StringLab" ^ Int.toString(incr())))
      fun new_float_lab() : lab = DatLab(Labels.new_named ("FloatLab" ^ Int.toString(incr())))
      fun reset_label_counter() = counter := 0
    end

    (* Static Data *)
    local
      val static_data : RiscInst list ref = ref []
    in
      fun add_static_data (insts) = (static_data := insts @ !static_data)
      fun reset_static_data () = static_data := []
      fun get_static_data C = !static_data @ C
    end

    (* Convert ~n to -n *)
    fun int_to_string i =
      if i >= 0 then Int.toString i
      else "-" ^ Int.toString (~i)

    (* We make the offset base explicit in the following functions *)
    datatype Offset = 
        WORDS of int 
      | BYTES of int
      | IMMED of int

    (* Can be used to load from the stack or from a record *)     
    (* dst = base[x]                                       *)
    (* Kills Gen 1                                         *)
    fun load_indexed(dst_reg:reg,base_reg:reg,offset:Offset,C) =
      let
	val x = 
	  case offset of
	    BYTES x => x
	  | WORDS x => x*4
	  | _ => die "load_indexed: offset not in BYTES or WORDS"
      in
	if is_im14 x then
	  LDW{d=int_to_string x,s=Space 0,b=base_reg,t=dst_reg} :: C
	else
	  ADDIL{i="L'" ^ int_to_string x,r=base_reg} ::
	  LDW{d="R'" ^ int_to_string x,s=Space 0,b=Gen 1,t=dst_reg} :: C
      end

    (* Can be used to update the stack or store in a record *)
    (* base[x] = src                                        *)
    (* Kills Gen 1                                          *)
    fun store_indexed(base_reg:reg,offset:Offset,src_reg:reg,C) =
      let
	val x =
	  case offset of
	    BYTES x => x
	  | WORDS x => x*4
	  | _ => die "store_indexed: offset not in BYTES or WORDS"
      in
	if is_im14 x then
	  STW {r=src_reg,d=int_to_string x,s=Space 0,b=base_reg} :: C
	else
	  ADDIL {i="L'" ^ int_to_string x,r=base_reg} ::
	  STW {r=src_reg,d="R'" ^ int_to_string x,s=Space 0,b=Gen 1} :: C
      end

    (* Calculate an addres given a base and an offset *)
    (* dst = base + x                                 *)
    (* Kills Gen 1                                    *)
    fun base_plus_offset(base_reg:reg,offset:Offset,dst_reg:reg,C) =
      let
	val x = 
	  case offset of
	    BYTES x => x
	  | WORDS x => x*4
	  | _ => die "base_plus_offset: offset not in BYTES or WORDS"
      in
	if is_im14 x then
	  LDO {d=int_to_string x,b=base_reg,t=dst_reg} :: C
	else
	  ADDIL {i="L'" ^ int_to_string x,r=base_reg} ::
	  LDO {d="R'" ^ int_to_string x,b=Gen 1,t=dst_reg} :: C
      end

    (* Load a constant *)
    (* dst = x         *)
    (* Kills no regs.  *)
    fun load_immed(IMMED x,dst_reg:reg,C) =
      if is_im14 x then 
	LDI {i=int_to_string x, t=dst_reg} :: C
      else 
	LDIL {i="L'" ^ int_to_string x, t=dst_reg} ::
	LDO {d="R'" ^ int_to_string x,b=dst_reg,t=dst_reg} :: C
      | load_immed _ = die "load_immed: immed not in IMMED"

    (* Find a register for aty and generate code to store into the aty *)
    fun resolve_aty_def(SS.STACK_ATY offset,t:reg,size_ff,C) = (t,store_indexed(sp,WORDS(~size_ff+offset),t,C))
      | resolve_aty_def(SS.PHREG_ATY phreg,t:reg,size_ff,C)  = (phreg,C)
      | resolve_aty_def _ = die "resolve_aty_def: ATY cannot be defined"

    (* Make sure that the aty ends up in register dst_reg *)
    fun move_aty_into_reg(SS.REG_I_ATY offset,dst_reg,size_ff,C) = base_plus_offset(sp,BYTES(~size_ff*4+offset*4+BI.inf_bit),dst_reg,C)
      | move_aty_into_reg(SS.REG_F_ATY offset,dst_reg,size_ff,C) = base_plus_offset(sp,WORDS(~size_ff+offset),dst_reg,C)
      | move_aty_into_reg(SS.STACK_ATY offset,dst_reg,size_ff,C) = load_indexed(dst_reg,sp,WORDS(~size_ff+offset),C)
      | move_aty_into_reg(SS.DROPPED_RVAR_ATY,dst_reg,size_ff,C) = C
      | move_aty_into_reg(SS.PHREG_ATY phreg,dst_reg,size_ff,C)  = if dst_reg = phreg then C else COPY{r=phreg,t=dst_reg} :: C
      | move_aty_into_reg(SS.INTEGER_ATY i,dst_reg,size_ff,C)    = load_immed(IMMED i,dst_reg,C) (* Integers are tagged in ClosExp *)
      | move_aty_into_reg(SS.UNIT_ATY,dst_reg,size_ff,C)         = load_immed(IMMED BI.ml_unit,dst_reg,C)

    (* dst_aty = src_reg *)
    fun move_reg_into_aty(src_reg:reg,dst_aty,size_ff,C) =
      case dst_aty of
	SS.PHREG_ATY dst_reg => 
	  if src_reg = dst_reg then
	    C
	  else 
	    COPY{r=src_reg,t=dst_reg} :: C
      | SS.STACK_ATY offset => store_indexed(sp,WORDS(~size_ff+offset),src_reg,C) 
      | _ => die "move_reg_into_aty: ATY not recognized"

    (* dst_aty = src_aty *)
    fun move_aty_to_aty(SS.PHREG_ATY src_reg,dst_aty,size_ff,C) = move_reg_into_aty(src_reg,dst_aty,size_ff,C)
      | move_aty_to_aty(src_aty,SS.PHREG_ATY dst_reg,size_ff,C) = move_aty_into_reg(src_aty,dst_reg,size_ff,C)
      | move_aty_to_aty(src_aty,dst_aty,size_ff,C) = 
      let
	val (reg_for_result,C') = resolve_aty_def(dst_aty,tmp_reg1,size_ff,C)
      in
	move_aty_into_reg(src_aty,reg_for_result,size_ff,C')
      end

    (* dst_aty = src_aty[offset] *)
    fun move_index_aty_to_aty(SS.PHREG_ATY src_reg,SS.PHREG_ATY dst_reg,offset:Offset,size_ff,C) = 
      load_indexed(dst_reg,src_reg,offset,C)
      | move_index_aty_to_aty(SS.PHREG_ATY src_reg,dst_aty,offset:Offset,size_ff,C) = 
      load_indexed(tmp_reg1,src_reg,offset,
		   move_reg_into_aty(tmp_reg1,dst_aty,size_ff,C))
      | move_index_aty_to_aty(src_aty,dst_aty,offset,size_ff,C) =
      move_aty_into_reg(src_aty,tmp_reg1,size_ff,
			load_indexed(tmp_reg1,tmp_reg1,offset,
				     move_reg_into_aty(tmp_reg1,dst_aty,size_ff,C)))
		   
    (* dst_aty = &lab *)
    (* Kills Gen 1    *)
    fun load_label_addr(lab,dst_aty,size_ff,C) = 
      let
	val (reg_for_result,C') = resolve_aty_def(dst_aty,tmp_reg1,size_ff,C)
      in
	ADDIL{i="L'" ^ pp_lab lab ^ "-$global$",r=dp} ::
	LDO{d="R'" ^ pp_lab lab ^ "-$global$",b=Gen 1,t=reg_for_result} :: C'
      end

    (* dst_aty = lab[0] *)
    (* Kills Gen 1      *)
    fun load_from_label(lab,dst_aty,tmp_reg:reg,size_ff,C) =
      let
	val (reg_for_result,C') = resolve_aty_def(dst_aty,tmp_reg,size_ff,C)
      in
	ADDIL{i="L'" ^ pp_lab lab ^ "-$global$",r=dp} ::
	LDW{d="R'" ^ pp_lab lab ^ "-$global$",b=Gen 1,t=reg_for_result,s=Space 0} :: C'
      end

    (* lab[0] = src_aty *)
    (* Kills Gen 1      *)
    fun store_in_label(SS.PHREG_ATY src_reg,label,tmp1:reg,size_ff,C) =
      ADDIL{i="L'" ^ pp_lab label ^ "-$global$",r=dp} ::
      STW{r=src_reg,d="R'" ^ pp_lab label ^ "-$global$",b=Gen 1,s=Space 0} :: C
      | store_in_label(src_aty,label,tmp1:reg,size_ff,C) =
      move_aty_into_reg(src_aty,tmp1,size_ff,
			ADDIL{i="L'" ^ pp_lab label ^ "-$global$",r=dp} ::
			STW{r=tmp1,d="R'" ^ pp_lab label ^ "-$global$",s=Space 0,b=Gen 1} :: C)

(* Generate a string label *)
    fun gen_string_lab str =
      let
	val string_lab = new_string_lab()
	val _ = add_static_data [DOT_DATA,
				 DOT_ALIGN 4,
				 LABEL string_lab,
				 DOT_WORD(Int.toString(size(str)*8+BI.value_tag_string)),
				 DOT_WORD (Int.toString(size(str))),
				 DOT_WORD "0", (* NULL pointer to next fragment. *)
				 DOT_STRINGZ str]
      in
	string_lab
      end

    (* Generate a Data label *)
    fun gen_data_lab lab =
      add_static_data [DOT_DATA,
		       DOT_ALIGN 4,
		       LABEL(DatLab lab),
		       DOT_WORD "0"]

    (* Can be used to update the stack or a record when the argument is an ATY *)
    (* base_reg[offset] = src_aty *)
    fun store_aty_in_reg_record(SS.PHREG_ATY src_reg,tmp_reg:reg,base_reg,offset:Offset,size_ff,C) =
      store_indexed(base_reg,offset,src_reg,C)
      | store_aty_in_reg_record(src_aty,tmp_reg:reg,base_reg,offset:Offset,size_ff,C) =
      move_aty_into_reg(src_aty,tmp_reg,size_ff,
		  store_indexed(base_reg,offset,tmp_reg,C))

    (* Can be used to load form the stack or a record when destination is an ATY *)
    (* dst_aty = base_reg[offset] *)
    fun load_aty_from_reg_record(SS.PHREG_ATY dst_reg,tmp_reg:reg,base_reg,offset:Offset,size_ff,C) =
      load_indexed(dst_reg,base_reg,offset,C)
      | load_aty_from_reg_record(dst_aty,tmp_reg:reg,base_reg,offset:Offset,size_ff,C) =
      load_indexed(tmp_reg,base_reg,offset,
		   move_reg_into_aty(tmp_reg,dst_aty,size_ff,C))

    (* base_aty[offset] = src_aty *)
    fun store_aty_in_aty_record(SS.PHREG_ATY src_reg,SS.PHREG_ATY base_reg,offset:Offset,tmp_reg1,tmp_reg2,size_ff,C) =
      store_indexed(base_reg,offset,src_reg,C)
      | store_aty_in_aty_record(SS.PHREG_ATY src_reg,base_aty,offset:Offset,tmp_reg1,tmp_reg2,size_ff,C) =
      move_aty_into_reg(base_aty,tmp_reg2,size_ff,
			store_indexed(tmp_reg2,offset,src_reg,C))
      | store_aty_in_aty_record(src_aty,SS.PHREG_ATY base_reg,offset:Offset,tmp_reg1,tmp_reg2,size_ff,C) =
      move_aty_into_reg(src_aty,tmp_reg1,size_ff,
			store_indexed(base_reg,offset,tmp_reg1,C))
      | store_aty_in_aty_record(src_aty,base_aty,offset:Offset,tmp_reg1,tmp_reg2,size_ff,C) =
      move_aty_into_reg(src_aty,tmp_reg1,size_ff,
			move_aty_into_reg(base_aty,tmp_reg2,size_ff,
					  store_indexed(tmp_reg2,offset,tmp_reg1,C)))

    (* push(aty), i.e., sp[0] = aty ; sp+=4 *)
    (* size_ff is for sp before sp is moved. *)
    fun push_aty(SS.PHREG_ATY aty_reg,tmp_reg:reg,size_ff,C) = STWM{r=aty_reg,d="4",s=Space 0,b=sp} :: C
      | push_aty(aty,tmp_reg:reg,size_ff,C) = move_aty_into_reg(aty,tmp_reg,size_ff,
								STWM{r=tmp_reg,d="4",s=Space 0,b=sp} :: C)
	 
    (* pop(aty), i.e., sp-=4; aty=sp[0] *)
    (* size_ff is for sp after pop *)
    fun pop_aty(SS.PHREG_ATY aty_reg,tmp_reg:reg,size_ff,C) = LDWM{d="-4",s=Space 0,b=sp,t=aty_reg} :: C
      | pop_aty(aty,tmp_reg:reg,size_ff,C) =
      LDWM{d="-4",s=Space 0,b=sp,t=tmp_reg} ::
      move_reg_into_aty(tmp_reg,aty,size_ff,C)

    (* Returns a register with arg and a continuation function. *)
    fun resolve_arg_aty(arg: SS.Aty, tmp:reg, size_ff:int) : reg * (RiscInst list -> RiscInst list) =
      case arg
	of SS.PHREG_ATY r => (r, fn C => C)
	 | _ => (tmp, fn C => move_aty_into_reg(arg, tmp, size_ff, C))

    (* Returns a floating point register and a continuation function. *)
    fun resolve_float_aty_arg(float_aty,tmp_reg,tmp_float,size_ff) =
      let 
	val disp = 
	  if !BI.tag_values then 
	    "8" 
	  else 
	    "0"
      in 
	case float_aty of
	  SS.PHREG_ATY x => (tmp_float,fn C => FLDDS{complt=EMPTY,d=disp,s=Space 0,b=x,t=tmp_float} :: C)
	| _ => (tmp_float,fn C => move_aty_into_reg(float_aty,tmp_reg,size_ff,
						    FLDDS{complt=EMPTY,d=disp,s=Space 0,b=tmp_reg,t=tmp_float} :: C))
      end

    fun box_float_reg(base_reg,float_reg,C) =
      if !BI.tag_values then
	load_immed(IMMED BI.value_tag_real,tmp_reg2,
		   STW{r=tmp_reg2,d="0",s=Space 0,b=base_reg} ::
		   FSTDS{complt=EMPTY,r=float_reg,d="8",s=Space 0,b=base_reg} :: C)
      else
	FSTDS {complt=EMPTY,r=float_reg,d="0",s=Space 0,b=base_reg} :: C
  
    (***********************)
    (* Calling C Functions *)
    (***********************)
    (* Kills tmp_reg1 and tmp_reg2 *)
    fun align_stack C = (* MEGA HACK *)
      COPY {r=sp, t=tmp_reg0} ::
      load_immed(IMMED 60,tmp_reg3,
		 ANDCM{cond=NEVER,r1=tmp_reg3,r2=sp,t=tmp_reg3} ::
		 ADD{cond=NEVER,r1=tmp_reg3,r2=sp,t=sp} ::
		 STWM {r=tmp_reg0,d="1028",s=Space 0,b=sp} :: C)

    (* Kills no registers. *)      
    fun restore_stack C = LDW {d="-1028",s=Space 0,b=sp,t=sp} :: C

    fun compile_c_call_prim(name: string,args: SS.Aty list,opt_ret: SS.Aty option,size_ff:int,tmp_reg:reg,C) =
      let
	val _ = add_lib_function name
	val (convert: bool,name: string) =
	  (case explode name of
	     #"@" :: rest => (!BI.tag_values, implode rest)
	   | _ => (false, name))

	fun convert_int_to_c(reg,C) =
	  if convert then 
	    SHD {cond=NEVER, r1=Gen 0, r2=reg, p="1" , t=reg} :: C
	  else 
	    C

	fun convert_int_to_ml(reg,C) =
	  if convert then 
	    SH1ADD {cond=NEVER, r1=reg, r2=Gen 0, t=reg} ::
	    LDO {d="1", b=reg, t=reg} :: C
	  else 
	    C

	fun arg_str(n,[]) = ""
	  | arg_str(n,[a]) = "ARGW" ^ Int.toString n ^ "=GR"
	  | arg_str(n,a::rest) = 
	  if n<3 then 
	    arg_str(n,[a]) ^ ", " ^ arg_str(n+1,rest)
	  else 
	    arg_str(n,[a]) 

	val call_str = arg_str(0,args) ^ 
	  (case opt_ret 
	     of SOME _ => (if length args > 0 then ", " else "") ^ "RTNVAL=GR" 
	      | NONE => "")

	fun fetch_args_ext([],_,C) = C
	  | fetch_args_ext(r::rs,offset,C) = 
	  move_aty_into_reg(r,tmp_reg,size_ff,
			    convert_int_to_c(tmp_reg,
					     STW{r=tmp_reg,d="-" ^ Int.toString offset,s=Space 0,b=sp} :: fetch_args_ext(rs,offset+4,C)))

	fun fetch_args([],_,C) = C
	  | fetch_args(r::rs,ar::ars,C) = 
	  move_aty_into_reg(r,ar,size_ff,
			    convert_int_to_c(ar,
					     fetch_args(rs,ars,C)))
	  | fetch_args(rs,[],C) = fetch_args_ext(rs,52,align_stack C) (* arg4 is at offset sp-52 *)

	fun store_ret(SOME d,C) = 
	  convert_int_to_ml(ret0,
			    move_reg_into_aty(ret0,d,size_ff,C))
	  | store_ret(NONE,C) = C
      in
	fetch_args(args,[arg0, arg1, arg2, arg3],
		   align_stack(META_BL{n=false,target=NameLab name,rpLink=rp,callStr=call_str} ::
			       restore_stack(store_ret(opt_ret,C))))
      end

    (*********************)
    (* Allocation Points *)
    (*********************)

    (* Status Bits Are Not Cleared          *)
    (* We preserve the value in register t, *)
    (* t may be used in a call to alloc     *)
    fun reset_region(t:reg,size_ff,C) = compile_c_call_prim("resetRegion",[SS.PHREG_ATY t],SOME(SS.PHREG_ATY t),size_ff,tmp_reg0(*not used*),C)

    (* Status Bits Are Not Cleared *)
    fun alloc(t:reg,n:int,size_ff,C) = compile_c_call_prim("alloc",[SS.PHREG_ATY t,SS.INTEGER_ATY n],SOME(SS.PHREG_ATY t),size_ff,tmp_reg0(*not used*),C)

    fun clear_status_bits(t,C) = DEPI{cond=NEVER,i="0",p="31",len="2",t=t}::C
    fun set_atbot_bit(dst_reg:reg,C) = DEPI{cond=NEVER,i="1",p="30",len="1",t=dst_reg} :: C
    fun clear_atbot_bit(dst_reg:reg,C) = DEPI{cond=NEVER,i="0",p="30",len="1",t=dst_reg} :: C
    fun set_inf_bit(dst_reg:reg,C) = DEPI{cond=NEVER,i="1",p="31",len="1",t=dst_reg} :: C

    (* move_aty_into_reg_ap differs from move_aty_into_reg in the case where aty is a phreg! *)
    (* We must always make a copy of phreg because we may overwrite status bits in phreg.    *) 
    fun move_aty_into_reg_ap(aty,dst_reg,size_ff,C) =
      (case aty of
	 SS.REG_I_ATY offset =>  base_plus_offset(sp,BYTES(~size_ff*4+offset*4(*+BI.inf_bit*)),dst_reg,
						  set_inf_bit(dst_reg,C))
       | SS.REG_F_ATY offset => base_plus_offset(sp,WORDS(~size_ff+offset),dst_reg,C)
       | SS.STACK_ATY offset => load_indexed(dst_reg,sp,WORDS(~size_ff+offset),C)
       | SS.PHREG_ATY phreg  => COPY {r=phreg,t=dst_reg} :: C
       | _ => die "move_aty_into_reg_ap: ATY cannot be used to allocate memory")

    fun alloc_ap(sma,dst_reg:reg,n,size_ff,C) =
      (case sma of
	 LS.ATTOP_LI(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.ATTOP_LF(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.ATTOP_FI(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.ATTOP_FF(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.ATBOT_LI(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.ATBOT_LF(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.SAT_FI(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.SAT_FF(SS.DROPPED_RVAR_ATY,pp) => C
       | LS.IGNORE => C
       | LS.ATTOP_LI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,alloc(dst_reg,n,size_ff,C))
       | LS.ATTOP_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
       | LS.ATTOP_FI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,alloc(dst_reg,n,size_ff,C))
       | LS.ATTOP_FF(aty,pp) => 
	   let
	     val default_lab = new_local_lab "no_alloc"
	   in
	     move_aty_into_reg_ap(aty,dst_reg,size_ff,
				  META_IF_BIT{r=dst_reg,bitNo=31,target=default_lab} :: (* inf bit set? *)
				  alloc(dst_reg,n,size_ff,LABEL default_lab :: C))
	   end
       | LS.ATBOT_LI(aty,pp) => 
	   move_aty_into_reg_ap(aty,dst_reg,size_ff,
				reset_region(dst_reg,size_ff, (* dst_reg is preserved for alloc *)
					     alloc(dst_reg,n,size_ff,C)))
       | LS.ATBOT_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C) (* atbot bit not set; its a finite region *)
       | LS.SAT_FI(aty,pp) => 
	   let
	     val default_lab = new_local_lab "no_reset"
	   in
	     move_aty_into_reg_ap(aty,dst_reg,size_ff,
				  META_IF_BIT{r=dst_reg,bitNo=30,target=default_lab} :: (* atbot bit set? *)
				  reset_region(dst_reg,size_ff,LABEL default_lab ::  (* dst_reg is preverved over the call *)
					       alloc(dst_reg,n,size_ff,C)))
	   end
       | LS.SAT_FF(aty,pp) => 
	   let
	     val finite_lab = new_local_lab "no_alloc"
	     val attop_lab = new_local_lab "no_reset"
	   in
	     move_aty_into_reg_ap(aty,dst_reg,size_ff,
				  META_IF_BIT{r=dst_reg,bitNo=31,target=finite_lab} :: (* inf bit set? *)
				  META_IF_BIT{r=dst_reg,bitNo=30,target=attop_lab} ::  (* atbot bit set? *)
				  reset_region(dst_reg,size_ff,LABEL attop_lab ::  (* dst_reg is preserved over the call *)
					       alloc(dst_reg,n,size_ff,LABEL finite_lab :: C)))
	   end)

    (* Set Atbot bits on region variables *)
    fun prefix_sm(sma,dst_reg:reg,size_ff,C) = 
      (case sma of
	 LS.ATTOP_LI(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.ATTOP_LF(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.ATTOP_FI(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.ATTOP_FF(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.ATBOT_LI(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.ATBOT_LF(SS.DROPPED_RVAR_ATY,pp) => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.SAT_FI(SS.DROPPED_RVAR_ATY,pp)   => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.SAT_FF(SS.DROPPED_RVAR_ATY,pp)   => die "prefix_sm: DROPPED_RVAR_ATY not implemented."
       | LS.IGNORE                           => die "prefix_sm: IGNORE not implemented."
       | LS.ATTOP_LI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
       | LS.ATTOP_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
       | LS.ATTOP_FI(aty,pp) => 
	   move_aty_into_reg_ap(aty,dst_reg,size_ff,
				clear_atbot_bit(dst_reg,C))
       | LS.ATTOP_FF(aty,pp) => 
	   move_aty_into_reg_ap(aty,dst_reg,size_ff, 
				clear_atbot_bit(dst_reg,C)) (* It is necessary to clear atbot bit because the region may be infinite *)
       | LS.ATBOT_LI(SS.REG_I_ATY offset_reg_i,pp) => 
	   base_plus_offset(sp,BYTES(~size_ff*4+offset_reg_i*4(*+BI.inf_bit+BI.atbot_bit*)),dst_reg,
			    set_inf_bit(dst_reg,
					set_atbot_bit(dst_reg,C)))
       | LS.ATBOT_LI(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,set_atbot_bit(dst_reg,C))
       | LS.ATBOT_LF(aty,pp) => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
       | LS.SAT_FI(aty,pp)   => move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
       | LS.SAT_FF(aty,pp)   => move_aty_into_reg_ap(aty,dst_reg,size_ff,C))

    (* Used to build a region vector *)
    fun store_sm_in_record(sma,tmp:reg,base_reg,offset,size_ff,C) = 
      (case sma of
	 LS.ATTOP_LI(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.ATTOP_LF(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.ATTOP_FI(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.ATTOP_FF(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.ATBOT_LI(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.ATBOT_LF(SS.DROPPED_RVAR_ATY,pp) => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.SAT_FI(SS.DROPPED_RVAR_ATY,pp)   => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.SAT_FF(SS.DROPPED_RVAR_ATY,pp)   => die "store_sm_in_record: DROPPED_RVAR_ATY not implemented."
       | LS.IGNORE                           => die "store_sm_in_record: IGNORE not implemented."
       | LS.ATTOP_LI(SS.PHREG_ATY phreg,pp)  => store_indexed(base_reg,offset,phreg,C)
       | LS.ATTOP_LI(aty,pp)                 => move_aty_into_reg_ap(aty,tmp,size_ff,
								     store_indexed(base_reg,offset,tmp,C))
       | LS.ATTOP_LF(SS.PHREG_ATY phreg,pp)  => store_indexed(base_reg,offset,phreg,C)
       | LS.ATTOP_LF(aty,pp)                 => move_aty_into_reg_ap(aty,tmp,size_ff,
								     store_indexed(base_reg,offset,tmp,C))
       | LS.ATTOP_FI(aty,pp)                 => move_aty_into_reg_ap(aty,tmp,size_ff,
								     clear_atbot_bit(tmp,
										     store_indexed(base_reg,offset,tmp,C)))
       | LS.ATTOP_FF(aty,pp)                 => move_aty_into_reg_ap(aty,tmp,size_ff,
								     clear_atbot_bit(tmp, (* The region may be infinite so we clear the atbot bit *)
										     store_indexed(base_reg,offset,tmp,C)))
       | LS.ATBOT_LI(SS.REG_I_ATY offset_reg_i,pp) => 
	   base_plus_offset(sp,BYTES(~size_ff*4+offset_reg_i*4(*+BI.inf_bit+BI.atbot_bit*)),tmp,
			    set_inf_bit(tmp,
					set_atbot_bit(tmp,
						      store_indexed(base_reg,offset,tmp,C))))
       | LS.ATBOT_LI(aty,pp) => 
	   move_aty_into_reg_ap(aty,tmp,size_ff,
				set_atbot_bit(tmp,
					      store_indexed(base_reg,offset,tmp,C)))
       | LS.ATBOT_LF(SS.PHREG_ATY phreg,pp) => store_indexed(base_reg,offset,phreg,C) (* The region is finite so no atbot bit is necessary *)
       | LS.ATBOT_LF(aty,pp) => 
	   move_aty_into_reg_ap(aty,tmp,size_ff,
				store_indexed(base_reg,offset,tmp,C))
       | LS.SAT_FI(SS.PHREG_ATY phreg,pp) => store_indexed(base_reg,offset,phreg,C) (* The storage bit is already recorded in phreg *)
       | LS.SAT_FI(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
						   store_indexed(base_reg,offset,tmp,C))
       | LS.SAT_FF(SS.PHREG_ATY phreg,pp) => store_indexed(base_reg,offset,phreg,C) (* The storage bit is already recorded in phreg *)
       | LS.SAT_FF(aty,pp) => move_aty_into_reg_ap(aty,tmp,size_ff,
						   store_indexed(base_reg,offset,tmp,C)))

(*      fun maybe_reset_region(LS.ATTOP_LI(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.ATTOP_LF(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.ATTOP_FI(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.ATTOP_FF(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.ATBOT_LI(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.ATBOT_LF(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.SAT_FI(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.SAT_FF(SS.DROPPED_RVAR_ATY,pp),dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.IGNORE,dst_reg:reg,size_ff,C) = C
	| maybe_reset_region(LS.ATBOT_LI(aty,pp),dst_reg:reg,size_ff,C) = 
	move_aty_into_reg_ap(aty,dst_reg,size_ff,
			     reset_region(dst_reg,size_ff,C))
	| maybe_reset_region(LS.SAT_FI(aty,pp),dst_reg:reg,size_ff,C) = 
	let
	  val default_lab = new_local_lab "no_reset"
	in
	  move_aty_into_reg_ap(aty,dst_reg,size_ff,
			       META_IF_BIT{r=dst_reg,bitNo=30,target=default_lab} ::
			       reset_region(dst_reg,size_ff,LABEL default_lab :: C))
	end
	| maybe_reset_region(LS.SAT_FF(aty,pp),dst_reg:reg,size_ff,C) = 
	let
	  val default_lab = new_local_lab "no_reset"
	in
	  move_aty_into_reg_ap(aty,dst_reg,size_ff,
			       META_IF_BIT{r=dst_reg,bitNo=31,target=default_lab} ::
			       META_IF_BIT{r=dst_reg,bitNo=30,target=default_lab} ::
			       reset_region(dst_reg,size_ff,LABEL default_lab :: C))
	end
	| maybe_reset_region(LS.ATTOP_LI(aty,pp),dst_reg:reg,size_ff,C) = move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
	| maybe_reset_region(LS.ATTOP_LF(aty,pp),dst_reg:reg,size_ff,C) = move_aty_into_reg_ap(aty,dst_reg,size_ff,C) (* status bits are not set *)
	| maybe_reset_region(LS.ATTOP_FI(aty,pp),dst_reg:reg,size_ff,C) = move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
	| maybe_reset_region(LS.ATTOP_FF(aty,pp),dst_reg:reg,size_ff,C) = move_aty_into_reg_ap(aty,dst_reg,size_ff,C)
        | maybe_reset_region(LS.ATBOT_LF(aty,pp),dst_reg:reg,size_ff,C) = move_aty_into_reg_ap(aty,dst_reg,size_ff,C) (* status bits are not set *)*)

      fun force_reset_aux_region(sma,tmp_reg:reg,size_ff,C) = 
	(case sma of
	   LS.ATBOT_LI(aty,pp) => move_aty_into_reg_ap(aty,tmp_reg,size_ff,
						       reset_region(tmp_reg,size_ff,C))
	 | LS.SAT_FI(aty,pp) => move_aty_into_reg_ap(aty,tmp_reg,size_ff, (* We do not check the storage mode *)
						     reset_region(tmp_reg,size_ff,C))
	 | LS.SAT_FF(aty,pp) => 
	     let
	       val default_lab = new_local_lab "no_reset"
	     in
	       move_aty_into_reg_ap(aty,tmp_reg,size_ff, (* We check the inf bit but not the storage mode *)
				    META_IF_BIT{r=tmp_reg,bitNo=31,target=default_lab} :: (* Is region infinite? *)
				    reset_region(tmp_reg,size_ff,LABEL default_lab :: C))
	     end
	| _ => C)

      fun maybe_reset_aux_region(sma,tmp_reg:reg,size_ff,C) = 
	(case sma of
	   LS.ATBOT_LI(aty,pp) => move_aty_into_reg_ap(aty,tmp_reg,size_ff,
						       reset_region(tmp_reg,size_ff,C))
	 | LS.SAT_FI(aty,pp) => 
	     let
	       val default_lab = new_local_lab "no_reset"
	     in
	       move_aty_into_reg_ap(aty,tmp_reg,size_ff,
				    META_IF_BIT{r=tmp_reg,bitNo=30,target=default_lab} :: (* Is storage mode atbot? *)
				    reset_region(tmp_reg,size_ff,LABEL default_lab :: C))
	     end
	| LS.SAT_FF(aty,pp) => 
	     let
	       val default_lab = new_local_lab "no_reset"
	     in
	       move_aty_into_reg_ap(aty,tmp_reg,size_ff,
				    META_IF_BIT{r=tmp_reg,bitNo=31,target=default_lab} :: (* Is region infinite? *)
				    META_IF_BIT{r=tmp_reg,bitNo=30,target=default_lab} :: (* Is atbot bit set? *)
				    reset_region(tmp_reg,size_ff,LABEL default_lab :: C))
	     end
	| _ => C)

      (* Compile Switch Statements *)
      local
	fun comment(str,C) = COMMENT str :: C
	fun new_label str = new_local_lab str
	fun label(lab,C) = LABEL lab :: C
	fun jmp(lab,C) = META_B{n=false,target=lab} :: C
      in
	fun linear_search(sels,
			  default,
			  compile_sel:'sel * RiscInst list -> RiscInst list,
			  if_no_match_go_lab: lab * RiscInst list -> RiscInst list,
			  compile_insts,C) =
	  JumpTables.linear_search(sels,
				   default,
				   comment,
				   new_label,
				   compile_sel,
				   if_no_match_go_lab,
				   compile_insts,
				   label,jmp,C)
      end

      fun cmpi(cond,x:reg,y:reg,d:reg,C) = 
	LDI {i=int_to_string BI.ml_true, t=d} ::
	COMCLR {cond=cond,r1=x,r2=y,t=Gen 1} ::
	LDI {i=int_to_string BI.ml_false,t=d} :: C

      fun maybe_tag_integers(inst,C) =		  
	if !BI.tag_integers then
	  inst :: C
	else
	  C
		  
      fun muli(x:reg,y:reg,d:reg,C) = (* A[i*j] = 1 + (A[i] >> 1) * (A[j]-1) *)
	if !BI.tag_integers then
	  (add_lib_function("$$mulI");
(*	   COPY{r=x,t=arg1} :: 28/12/1998, Niels*)
	   SHD{cond=NEVER,r1=Gen 0,r2=arg1,p="1",t=arg1} ::
(*	   COPY{r=y,t=arg0} :: 28/12/1998, Niels*)
	   LDO {d="-1",b=arg0,t=arg0} ::
	   META_BL {n=false,target=NameLab "$$mulI",rpLink=mrp, 
		    callStr=";in=25,26;out=29;(MILLICALL)"} ::
	   LDO{d="1",b=ret1,t=ret1} ::
	   COPY{r=ret1,t=d} :: C)
	else
	  (add_lib_function("$$muloI");
(*	   COPY{r=x,t=arg1} ::
	   COPY{r=y,t=arg0} :: 28/12/1998, Niels*)
	   META_BL {n=false,target=NameLab "$$muloI",rpLink=mrp, 
		    callStr=";in=25,26;out=29; (MILLICALL)"} ::
	   COPY{r=ret1,t=d} :: C)

      fun negi(x:reg,d:reg,C) = (* Exception Overflow not implemented *)
	let
	  val base = 
	    if !BI.tag_integers then 
	      "2" 
	    else 
	      "0"
	in
	  SUBI{cond=NEVER,i=base,r=x,t=d} :: C
	end

     fun absi(x:reg,d:reg,C) = (* Exception Overflow not implemented *)
       let
	 val base = 
	   if !BI.tag_integers then 
	     "2" 
	   else 
	     "0"
       in
	 ADD{cond=GREATERTHAN,r1=x,r2=Gen 0,t=d} ::
	 SUBI{cond=NEVER,i=base,r=x,t=d} :: C
       end

    fun addf(x,y,b,d,size_ff,C) =
      let
	val (x_float_reg,x_C) = resolve_float_aty_arg(x,tmp_reg0,tmp_float_reg0,size_ff)
	val (y_float_reg,y_C) = resolve_float_aty_arg(y,tmp_reg0,tmp_float_reg1,size_ff)
	val (b_reg,b_C) = resolve_arg_aty(b,tmp_reg0,size_ff)
	val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
      in
	x_C(y_C(FADD{fmt=DBL,r1=x_float_reg,r2=y_float_reg,t=tmp_float_reg2} ::
		b_C(box_float_reg(b_reg,tmp_float_reg2,
				  COPY{r=b_reg,t=d_reg} :: C'))))
      end

    fun subf(x,y,b,d,size_ff,C) =
      let
	val (x_float_reg,x_C) = resolve_float_aty_arg(x,tmp_reg0,tmp_float_reg0,size_ff)
	val (y_float_reg,y_C) = resolve_float_aty_arg(y,tmp_reg0,tmp_float_reg1,size_ff)
	val (b_reg,b_C) = resolve_arg_aty(b,tmp_reg0,size_ff)
	val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
      in
	x_C(y_C(FSUB{fmt=DBL,r1=x_float_reg,r2=y_float_reg,t=tmp_float_reg2} ::
		b_C(box_float_reg(b_reg,tmp_float_reg2,
				  COPY{r=b_reg,t=d_reg} :: C'))))
      end

    fun mulf(x,y,b,d,size_ff,C) =
      let
	val (x_float_reg,x_C) = resolve_float_aty_arg(x,tmp_reg0,tmp_float_reg0,size_ff)
	val (y_float_reg,y_C) = resolve_float_aty_arg(y,tmp_reg0,tmp_float_reg1,size_ff)
	val (b_reg,b_C) = resolve_arg_aty(b,tmp_reg0,size_ff)
	val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
      in
	x_C(y_C(FMPY{fmt=DBL,r1=x_float_reg,r2=y_float_reg,t=tmp_float_reg2} ::
		b_C(box_float_reg(b_reg,tmp_float_reg2,
				  COPY{r=b_reg,t=d_reg} :: C'))))
      end

    fun divf(x,y,b,d,size_ff,C) =
      let
	val (b_reg,b_C) = resolve_arg_aty(b,tmp_reg0,size_ff)
	val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
      in
	compile_c_call_prim("divFloat",[b,x,y],NONE,size_ff,tmp_reg0,
			    b_C(if b_reg = d_reg then C' else COPY{r=b_reg,t=d_reg} :: C'))
      end

    fun negf(b,x,d,size_ff,C) =
      let
	val (x_float_reg,x_C) = resolve_float_aty_arg(x,tmp_reg0,tmp_float_reg0,size_ff)
	val (b_reg,b_C) = resolve_arg_aty(b,tmp_reg0,size_ff)
	val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
      in
	x_C(FSUB{fmt=DBL,r1=Float 0,r2=x_float_reg,t=tmp_float_reg0} ::
	    b_C(box_float_reg(b_reg,tmp_float_reg0,
			      COPY{r=b_reg,t=d_reg} :: C')))
      end

    fun absf(b,x,d,size_ff,C) =
      let
	val (x_float_reg,x_C) = resolve_float_aty_arg(x,tmp_reg0,tmp_float_reg0,size_ff)
	val (b_reg,b_C) = resolve_arg_aty(b,tmp_reg0,size_ff)
	val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
      in
	x_C(FABS{fmt=DBL,r=x_float_reg,t=tmp_float_reg0} ::
	    b_C(box_float_reg(b_reg,tmp_float_reg0,
			      COPY{r=b_reg,t=d_reg} :: C')))
      end

    fun cmpf(cond,x,y,d,size_ff,C) =
      let
	val (x_float_reg,x_C) = resolve_float_aty_arg(x,tmp_reg0,tmp_float_reg0,size_ff)
	val (y_float_reg,y_C) = resolve_float_aty_arg(y,tmp_reg0,tmp_float_reg1,size_ff)
	val (d_reg,C') = resolve_aty_def(d,tmp_reg0,size_ff,C)
      in
	(* Assume true; *)
	(* don't clear anything *)
	x_C(y_C(LDI{i=int_to_string BI.ml_true,t=d_reg} ::
		FCMP{fmt=DBL,cond=cond,r1=x_float_reg,r2=y_float_reg} ::
		FTEST ::
		LDI{i=int_to_string BI.ml_false,t=d_reg} :: C'))
      end

    (*******************)
    (* Code Generation *)
    (*******************)

    (* printing an assignment *)
    fun debug_assign(str,C) = C
(*      if Flags.is_on "debug_codeGen" then
      let
	val string_lab = gen_string_lab (str ^ "\n")
      in
	COMMENT "Start of Debug Assignment" ::
	load_label_addr(string_lab,SS.PHREG_ATY arg0,0,
			compile_c_call_prim("printString",[SS.PHREG_ATY arg0],NONE,0,tmp_reg0 (*not used*),
					    COMMENT "End of Debug Assignment" :: C))
      end
      else C*)

    fun CG_lss(lss,size_ff,size_cc,size_rcf,size_ccf,C) =
      let
	fun pr_ls ls = LS.pr_line_stmt SS.pr_sty SS.pr_offset SS.pr_aty true ls
	fun not_impl(s,C) = COMMENT s :: C
	fun CG_ls(ls,C) = 
	  (case ls of
	     LS.ASSIGN{pat,bind} =>
	       debug_assign(pr_ls ls,
	       COMMENT (pr_ls ls) :: 
	       (case bind of
		  LS.ATOM src_aty => move_aty_to_aty(src_aty,pat,size_ff,C)
		| LS.LOAD label => load_from_label(DatLab label,pat,tmp_reg1,size_ff,C)
		| LS.STORE(src_aty,label) => 
		    (gen_data_lab label;
		     store_in_label(src_aty,DatLab label,tmp_reg1,size_ff,C))
		| LS.STRING str =>
		    let
		      val string_lab = gen_string_lab str
		    in
		      load_label_addr(string_lab,pat,size_ff,C)
		    end
		| LS.REAL str => 
		    let
		      val float_lab = new_float_lab()
		      val _ = 
			if !BI.tag_values then 
			  add_static_data [DOT_DATA,
					   DOT_ALIGN 8,
					   LABEL float_lab,
					   DOT_WORD (Int.toString BI.value_tag_real),
					   DOT_WORD "0", (* dummy *)
					   DOT_DOUBLE str]
			else
			  add_static_data [DOT_DATA,
					   DOT_ALIGN 8,
					   LABEL float_lab,
					   DOT_DOUBLE str]
		    in
		      load_label_addr(float_lab,pat,size_ff,C)
		    end
		| LS.CLOS_RECORD{label,elems,alloc} => 
		    let
		      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		      val num_elems = List.length elems
		    in
		      alloc_ap(alloc,reg_for_result,List.length elems + 1,size_ff,
			       load_label_addr(MLFunLab label,SS.PHREG_ATY tmp_reg2,size_ff,
					       store_indexed(reg_for_result,WORDS 0,tmp_reg2,
							     #2(foldr (fn (aty,(offset,C)) => 
								       (offset-1,store_aty_in_reg_record(aty,tmp_reg2,reg_for_result,WORDS offset,size_ff,
													 C))) (num_elems,C') elems))))
		    end
		| LS.REGVEC_RECORD{elems,alloc} =>
		    let
		      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		      val num_elems = List.length elems
		    in
		      alloc_ap(alloc,reg_for_result,List.length elems,size_ff,
			       #2(foldr (fn (sma,(offset,C)) => (offset-1,store_sm_in_record(sma,tmp_reg2,reg_for_result,WORDS offset,size_ff,
											     C))) (num_elems-1,C') elems))
		    end
		| LS.SCLOS_RECORD{elems,alloc} => 
		    let
		      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		      val num_elems = List.length elems
		    in
		      alloc_ap(alloc,reg_for_result,List.length elems,size_ff,
			       #2(foldr (fn (aty,(offset,C)) => (offset-1,store_aty_in_reg_record(aty,tmp_reg2,reg_for_result,WORDS offset,size_ff,
												  C))) (num_elems-1,C') elems))
		    end
		| LS.RECORD{elems=[],alloc} => move_aty_to_aty(SS.UNIT_ATY,pat,size_ff,C) (* Unit is unboxed *)
		| LS.RECORD{elems,alloc} =>
		    let
		      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
		      val num_elems = List.length elems
		    in
		      alloc_ap(alloc,reg_for_result,List.length elems,size_ff,
			       #2(foldr (fn (aty,(offset,C)) => (offset-1,store_aty_in_reg_record(aty,tmp_reg2,reg_for_result,WORDS offset,size_ff,
												  C))) (num_elems-1,C') elems))
		    end
		| LS.SELECT(i,aty) => move_index_aty_to_aty(aty,pat,WORDS i,size_ff,C)
		| LS.CON0{con,con_kind,aux_regions,alloc} =>
		    (case con_kind of
		       LS.ENUM i => 
			 let 
			   val tag = 
			     if !BI.tag_values orelse (*hack to treat booleans tagged*)
			       Con.eq(con,Con.con_TRUE) orelse Con.eq(con,Con.con_FALSE) then 
			       2*i+1 
			     else i
			   val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			 in
			   load_immed(IMMED tag,reg_for_result,C')
			 end
		     | LS.UNBOXED i => 
			 let
			   val tag = 4*i+3 
			   val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			   fun reset_regions C =
			     foldr (fn (alloc,C) => maybe_reset_aux_region(alloc,tmp_reg2,size_ff,C)) C aux_regions
			 in
			   reset_regions(load_immed(IMMED tag,reg_for_result,C'))
			 end
		     | LS.BOXED i => 
			 let 
			   val tag = 8*i + BI.value_tag_con0 
			   val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			   fun reset_regions C =
			     List.foldr (fn (alloc,C) => maybe_reset_aux_region(alloc,tmp_reg2,size_ff,C)) C aux_regions
			 in  
			   reset_regions(alloc_ap(alloc,reg_for_result,1,size_ff,
						  load_immed(IMMED tag,tmp_reg2,
							     store_indexed(reg_for_result,WORDS 0,tmp_reg2,C'))))
			 end)
		| LS.CON1{con,con_kind,alloc,arg} => 
		       (case con_kind of
			  LS.UNBOXED 0 => move_aty_to_aty(arg,pat,size_ff,C) 
			| LS.UNBOXED i => 
			    let
			      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			    in
			      (case i of
				 1 => move_aty_into_reg(arg,reg_for_result,size_ff,
							DEPI{cond=NEVER, i="1", p="31", len="1", t=reg_for_result} :: C')
			       | 2 => move_aty_into_reg(arg,reg_for_result,size_ff,
							DEPI{cond=NEVER, i="1", p="30", len="1", t=reg_for_result} :: C')
			       | _ => die "CG_ls: UNBOXED CON1 with i > 2")
			    end
			| LS.BOXED i => 
			    let
			      val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			      val tag = 8*i + BI.value_tag_con1
			    in
			      alloc_ap(alloc,reg_for_result,2,size_ff,
				       load_immed(IMMED tag,tmp_reg2,
						  store_indexed(reg_for_result,WORDS 0,tmp_reg2,
								store_aty_in_reg_record(arg,tmp_reg2,reg_for_result,WORDS 1,size_ff,C'))))
			    end
			| _ => die "CON1.con not unary in env.")
		| LS.DECON{con,con_kind,con_aty} =>
			  (case con_kind of
			     LS.UNBOXED 0 => move_aty_to_aty(con_aty,pat,size_ff,C)
			   | LS.UNBOXED _ => 
			       let
				 val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			       in
				 move_aty_into_reg(con_aty,reg_for_result,size_ff,
						   DEPI{cond=NEVER, i="0", p="31", len="2", t=reg_for_result} :: C')
			       end
			   | LS.BOXED _ => move_index_aty_to_aty(con_aty,pat,WORDS 1,size_ff,C)
			   | _ => die "CG_ls: DECON used with con_kind ENUM")
		| LS.DEREF aty =>
			     let
			       val offset = if !BI.tag_values then 1 else 0
			     in
			       move_index_aty_to_aty(aty,pat,WORDS offset,size_ff,C)
			     end
		| LS.REF(alloc,aty) =>
			     let
			       val offset = if !BI.tag_values then 1 else 0
			       val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			       fun maybe_tag_value C =
				 if !BI.tag_values then
				   load_immed(IMMED BI.value_tag_ref,tmp_reg2,
					      store_indexed(reg_for_result,WORDS 0,tmp_reg2,C))
				 else C
			     in
			       alloc_ap(alloc,reg_for_result,BI.size_of_ref(),size_ff,
					store_aty_in_reg_record(aty,tmp_reg2,reg_for_result,WORDS offset,size_ff,
								maybe_tag_value C'))
			     end
		| LS.ASSIGNREF(alloc,aty1,aty2) =>
			     let 
			       val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			       val offset = if !BI.tag_values then 1 else 0
			     in
			       store_aty_in_aty_record(aty2,aty1,WORDS offset,tmp_reg1,tmp_reg2,size_ff,
						       load_immed(IMMED BI.ml_unit,reg_for_result,C'))
			     end
		| LS.PASS_PTR_TO_MEM(alloc,i) =>
			     let
			       val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			     in
			       alloc_ap(alloc,reg_for_result,i,size_ff,C')
			     end
		| LS.PASS_PTR_TO_RHO(alloc) =>
			     let
			       val (reg_for_result,C') = resolve_aty_def(pat,tmp_reg1,size_ff,C)
			     in 
			       prefix_sm(alloc,reg_for_result,size_ff,C')
			     end))
	   | LS.FLUSH(aty,offset) => COMMENT (pr_ls ls) :: store_aty_in_reg_record(aty,tmp_reg1,sp,WORDS offset,size_ff,C)
	   | LS.FETCH(aty,offset) => COMMENT (pr_ls ls) :: load_aty_from_reg_record(aty,tmp_reg1,sp,WORDS offset,size_ff,C)
	   | LS.FNJMP(cc as{opr,args,clos,free,res}) =>
	       COMMENT (pr_ls ls) :: 
	       let
		 val (spilled_args,_,_) = CallConv.resolve_act_cc {args=args,clos=clos,free=free,reg_args=[],reg_vec=NONE,res=res}
	       in
		 if List.length spilled_args > 0 then
		     CG_ls(LS.FNCALL cc,C)
		 else
		     case opr of  (* We fetch the add from the closure and opr points at the closure *)
		       SS.PHREG_ATY opr_reg => 
			 LDW{d="0",s=Space 0,b=opr_reg,t=tmp_reg1} ::                (* Fetch code label from closure *)
			 base_plus_offset(sp,WORDS(~size_ff-size_ccf),sp,            (* return label is now at top of stack *)
					  META_BV{n=false,x=Gen 0,b=tmp_reg1} :: C)  (* Is C dead code? *)
		     | _ => move_aty_into_reg(opr,tmp_reg1,size_ff,
					      LDW{d="0",s=Space 0,b=tmp_reg1,t=tmp_reg1} ::             (* Fetch code label from closure *)
					      base_plus_offset(sp,WORDS(~size_ff-size_ccf),sp,          (* return label is now at top of stack *)
							       META_BV{n=false,x=Gen 0,b=tmp_reg1}::C)) (* Is C dead code? *)
	       end
	   | LS.FNCALL{opr,args,clos,free,res} =>
	       COMMENT (pr_ls ls) :: 
		  let
		    val (spilled_args,spilled_res,return_lab_offset) = CallConv.resolve_act_cc {args=args,clos=clos,free=free,reg_args=[],reg_vec=NONE,res=res}
		    val return_lab = new_local_lab "return_from_app"
		    fun flush_args C =
		      foldr (fn ((aty,offset),C) => push_aty(aty,tmp_reg1,size_ff+offset,C)) C spilled_args
		    fun fetch_res C =
		      foldr (fn ((aty,offset),C) => pop_aty(aty,tmp_reg1,size_ff+offset,C)) C (rev spilled_res) (* We pop in reverse order such that size_ff+offset works *)
		    fun jmp C = 
		      case opr of  (* We fetch the add from the closure and opr points at the closure *)
			SS.PHREG_ATY opr_reg => LDW{d="0",s=Space 0,b=opr_reg,t=tmp_reg1} :: META_BV{n=false,x=Gen 0,b=tmp_reg1} :: C
		      | _ => move_aty_into_reg(opr,tmp_reg1,size_ff+size_cc,  (* sp is now pointing after the call convention, i.e., size_ff+size_cc *)
					       LDW{d="0",s=Space 0,b=tmp_reg1,t=tmp_reg1} ::
					       META_BV{n=false,x=Gen 0,b=tmp_reg1}::C)
		  in
		    load_label_addr(return_lab,SS.PHREG_ATY tmp_reg1,size_ff,                 (* Fetch return label address *)
				    base_plus_offset(sp,WORDS(size_rcf),sp,                   (* Move sp after rcf *)
						     STWM{r=tmp_reg1,d="4",s=Space 0,b=sp} :: (* Push Return Label *)
						     flush_args(jmp(LABEL return_lab :: fetch_res C))))
		  end
	   | LS.JMP(cc as {opr,args,reg_vec,reg_args,clos,free,res}) => 
		  COMMENT (pr_ls ls) :: 
		  let
		    val (spilled_args,_,_) = CallConv.resolve_act_cc {args=args,clos=clos,free=free,reg_args=reg_args,reg_vec=reg_vec,res=res}
		    fun jmp C = META_B{n=false,target=MLFunLab opr} :: C (* Is C dead code? *)
		  in
		    if List.length spilled_args > 0 then
		      CG_ls(LS.FUNCALL cc,C)
		    else
		      base_plus_offset(sp,WORDS(~size_ff-size_ccf),sp,
				       jmp C)
		  end
	   | LS.FUNCALL{opr,args,reg_vec,reg_args,clos,free,res} =>
		  COMMENT (pr_ls ls) :: 
		  let
		    val (spilled_args,spilled_res,return_lab_offset) = CallConv.resolve_act_cc {args=args,clos=clos,free=free,reg_args=reg_args,reg_vec=reg_vec,res=res}
		    val return_lab = new_local_lab "return_from_app"
		    fun flush_args C =
		      foldr (fn ((aty,offset),C) => push_aty(aty,tmp_reg1,size_ff+offset,C)) C spilled_args
		    fun fetch_res C =
		      foldr (fn ((aty,offset),C) => pop_aty(aty,tmp_reg1,size_ff+offset,C)) C (rev spilled_res) (* We pop in reverse order such that size_ff+offset works *)
		    fun jmp C = META_B{n=false,target=MLFunLab opr} :: C
		  in
		    load_label_addr(return_lab,SS.PHREG_ATY tmp_reg1,size_ff,                 (* Fetch return label address *)
				    base_plus_offset(sp,WORDS(size_rcf),sp,                   (* Move sp after rcf *)
						     STWM{r=tmp_reg1,d="4",s=Space 0,b=sp} :: (* Push Return Label *)
						     flush_args(jmp(LABEL return_lab :: fetch_res C))))
		  end
	   | LS.LETREGION{rhos,body} =>
		  COMMENT "letregion" :: 
		  let
		    fun alloc_region_prim((_,offset),C) = 
		      base_plus_offset(sp,WORDS(~size_ff+offset),tmp_reg1,
				       compile_c_call_prim("allocateRegion",[SS.PHREG_ATY tmp_reg1],NONE,size_ff,tmp_reg0(*not used*),C))
		    fun dealloc_region_prim C = 
		      compile_c_call_prim("deallocateRegionNew",[],NONE,size_ff,tmp_reg0(*not used*),C)
		    fun remove_finite_rhos([]) = []
		      | remove_finite_rhos(((place,LineStmt.WORDS i),offset)::rest) = remove_finite_rhos rest
		      | remove_finite_rhos(rho::rest) = rho :: remove_finite_rhos rest
		    val rhos_to_allocate = remove_finite_rhos rhos
		  in
		    foldr alloc_region_prim 
		    (CG_lss(body,size_ff,size_cc,size_rcf,size_ccf,
			    foldl (fn (_,C) => dealloc_region_prim C) C rhos_to_allocate)) rhos_to_allocate
		  end
	   | LS.SCOPE{pat,scope} => CG_lss(scope,size_ff,size_cc,size_rcf,size_ccf,C)
	   | LS.HANDLE{default,handl=(handl,handl_lv),handl_return=(handl_return,handl_return_aty),offset} =>
	   (* An exception handler in an activation record staring at address offset contains the following fields: *)
	   (* sp[offset] = label for handl_return code.                                                             *)
	   (* sp[offset+1] = pointer to handle closure.                                                             *)
	   (* sp[offset+2] = pointer to previous exception handler used when updating expPtr.                       *)
	   (* sp[offset+3] = address of the first cell after the activation record used when resetting sp.          *)
	   (* Note that we call deallocate_regions_until to the address above the exception handler, (i.e., some of *)
	   (* the infinite regions inside the activation record are also deallocated)!                              *)
	   let
	     val handl_return_lab = new_local_lab "handl_return"
	     val handl_join_lab = new_local_lab "handl_join"
	     fun handl_code C = COMMENT "HANDL_CODE" :: CG_lss(handl,size_ff,size_cc,size_rcf,size_ccf,C)
	     fun store_handl_lv C =
	       COMMENT "STORE HANDLE_LV: sp[offset+1] = handl_lv" ::
	       store_aty_in_reg_record(handl_lv,tmp_reg1,sp,WORDS(~size_ff+offset+1),size_ff,C) 
	     fun store_handl_return_lab C =
	       COMMENT "STORE HANDL RETURN LAB: sp[offset] = handl_return_lab" ::
	       load_label_addr(handl_return_lab,SS.PHREG_ATY tmp_reg1,size_ff,    
			       store_indexed(sp,WORDS(~size_ff+offset),tmp_reg1,C))
	     fun store_exn_ptr C =
	       COMMENT "STORE EXN PTR: sp[offset+2] = exnPtr" ::
	       load_from_label(exn_ptr_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,size_ff, 
			       store_indexed(sp,WORDS(~size_ff+offset+2),tmp_reg1,
					     COMMENT "CALC NEW expPtr: expPtr = sp-size_ff+offset+size_of_handle" ::
					     base_plus_offset(sp,WORDS(~size_ff+offset+BI.size_of_handle()),tmp_reg1,
							      store_in_label(SS.PHREG_ATY tmp_reg1,exn_ptr_lab,tmp_reg2,size_ff,C))))
	     fun store_sp C =
	       COMMENT "STORE SP: sp[offset+3] = sp" ::
	       store_indexed(sp,WORDS(~size_ff+offset+3),sp,C) 
	     fun default_code C = COMMENT "HANDLER DEFAULT CODE" :: 
	       CG_lss(default,size_ff,size_cc,size_rcf,size_ccf,C)
	     fun restore_exp_ptr C =
	       COMMENT "RESTORE EXP PTR: exnPtr = sp[offset+2]"::
	       load_indexed(tmp_reg1,sp,WORDS(~size_ff+offset+2),
			    store_in_label(SS.PHREG_ATY tmp_reg1,exn_ptr_lab,tmp_reg1,size_ff,
					   META_B{n=false,target=handl_join_lab} ::C))
	     fun handl_return_code C =
	       let
		 val res_reg = lv_to_reg(CallConv.handl_return_phreg())
	       in
		 COMMENT "HANDL RETRUN CODE: handl_return_aty = res_phreg" ::
		 LABEL handl_return_lab ::
		 move_aty_to_aty(SS.PHREG_ATY res_reg,handl_return_aty,size_ff,
				 CG_lss(handl_return,size_ff,size_cc,size_rcf,size_ccf,
					LABEL handl_join_lab :: C))
	       end
	   in
	     COMMENT "START OF EXCEPTION HANDLER" ::
	     handl_code(store_handl_lv(store_handl_return_lab(store_exn_ptr(store_sp(default_code(restore_exp_ptr(handl_return_code(
														  COMMENT "END OF EXCEPTION HANDLER" :: C))))))))
	   end
	   | LS.RAISE{arg=arg_aty,defined_atys} =>
	   (* To raise arg we fetch the top most exception handler and pass arg to the handler function.  *)
	   (* We put the label to which the handler function must return on top of the activation record. *)
	   (* arg_aty isn't currently preserved!!! Problem whit RA - should we reserve a slot in the handler! *)
	   let
	     val (clos_lv,arg_lv) = CallConv.handl_arg_phreg()
	     val (clos_reg,arg_reg) = (lv_to_reg clos_lv,lv_to_reg arg_lv)

	     fun deallocate_regions_until C =
	       COMMENT "DEALLOCATE REGIONS UNTIL" ::
	       load_from_label(exn_ptr_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,size_ff,
			       compile_c_call_prim("deallocateRegionsUntil",[SS.PHREG_ATY tmp_reg1],NONE,size_ff,tmp_reg1,C))
	     fun restore_exn_ptr C =
	       COMMENT "RESTORE EXN PTR" ::
	       load_from_label(exn_ptr_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,size_ff,
	       load_indexed(tmp_reg2,tmp_reg1,WORDS(~2),
			    store_in_label(SS.PHREG_ATY tmp_reg2,exn_ptr_lab,tmp_reg2,size_ff,C)))
	     fun push_return_lab C =
	       COMMENT "LOAD ARGUMENT, RESTORE SP AND PUSH RETURN LAB" ::
	       move_aty_into_reg(arg_aty,arg_reg,size_ff, (* Note that we are still in the activation record where arg_aty is raised *)
	       load_indexed(sp,tmp_reg1,WORDS(~1),        (* Restore sp *)
	       load_indexed(tmp_reg2,tmp_reg1,WORDS(~4),  (* Push Return Lab *)
			    STWM{r=tmp_reg2,d="4",s=Space 0,b=sp} :: C)))
	     fun jmp C =
		 COMMENT "JUMP TO HANDLE FUNCTION" ::
		 load_indexed(clos_reg,tmp_reg1,WORDS(~3), (* Fetch Closure into Closure Argument Register *)
			      LDW{d="0",s=Space 0,b=clos_reg,t=tmp_reg2} ::
			      META_BV{n=false,x=Gen 0,b=tmp_reg2}::C)
	   in
	     COMMENT ("START OF RAISE: " ^ pr_ls ls) ::
	     deallocate_regions_until(restore_exn_ptr(push_return_lab(jmp(COMMENT "END OF RAISE" :: C))))
	   end
	   | LS.SWITCH_I(LS.SWITCH(SS.PHREG_ATY opr_reg,sels,default)) => 
		  linear_search(sels,
				default,
				fn (i,C) => load_immed(IMMED i,tmp_reg2,C),
				fn (lab,C) => META_IF{cond=EQUAL,r1=opr_reg,r2=tmp_reg2,target=lab} :: C,
				fn (lss,C) => CG_lss (lss,size_ff,size_cc,size_rcf,size_ccf,C),
				C)
	   | LS.SWITCH_I(LS.SWITCH(opr_aty,sels,default)) =>
		  move_aty_into_reg(opr_aty,tmp_reg1,size_ff,
				    linear_search(sels,
						  default,
						  fn (i,C) => load_immed(IMMED i,tmp_reg2,C),
						  fn (lab,C) => META_IF{cond=EQUAL,r1=tmp_reg1,r2=tmp_reg2,target=lab} :: C,
						  fn (lss,C) => CG_lss (lss,size_ff,size_cc,size_rcf,size_ccf,C),
						  C))
	   | LS.SWITCH_S sw => die "SWITCH_S is unfolded in ClosExp"
	   | LS.SWITCH_C(LS.SWITCH(opr_aty,sels,default)) => 
		  let (* NOTE: selectors in sels are tagged in ClosExp but the operand is untagged here! *)
		    val con_kind = 
		      (case sels of
			 [] => die "CG_ls: SWITCH_C sels is empty"
		       | ((con,con_kind),_)::rest => con_kind)
		    val sels' = map (fn ((con,con_kind),sel_insts) => 
				     case con_kind of
				       LS.ENUM i => (i,sel_insts)
				     | LS.UNBOXED i => (i,sel_insts)
				     | LS.BOXED i => (i,sel_insts)) sels
		    fun UbTagCon(src_aty,C) =
		      move_aty_into_reg(src_aty,tmp_reg0,size_ff, 
					COPY{r=tmp_reg0, t=tmp_reg1} :: (* operand is in tmp_reg1, see SWITCH_I *)
					DEPI{cond=NEVER, i="0", p="29", len="30", t=tmp_reg1} ::
					ADDI{cond=NOTEQUAL, i="-3", r=tmp_reg1, t=Gen 1} ::      (* nullify copy if tr = 3 *)
					COPY{r=tmp_reg0, t=tmp_reg1} :: C)
		  in
		    (case con_kind of
		       LS.ENUM _ => CG_ls(LS.SWITCH_I(LS.SWITCH(opr_aty,sels',default)),C)
		     | LS.UNBOXED _ => UbTagCon(opr_aty,
						CG_ls(LS.SWITCH_I(LS.SWITCH(SS.PHREG_ATY tmp_reg1,sels',default)),C))
		     | LS.BOXED _ => move_index_aty_to_aty(opr_aty,SS.PHREG_ATY tmp_reg1,WORDS 0,size_ff,
							   CG_ls(LS.SWITCH_I(LS.SWITCH(SS.PHREG_ATY tmp_reg1,sels',default)),C)))
		  end
	   | LS.SWITCH_E sw => die "SWITCH_E is unfolded in ClosExp"
	   | LS.RESET_REGIONS{force=false,regions_for_resetting} =>
		  COMMENT (pr_ls ls) :: 
		  foldr (fn (alloc,C) => maybe_reset_aux_region(alloc,tmp_reg1,size_ff,C)) C regions_for_resetting
	   | LS.RESET_REGIONS{force=true,regions_for_resetting} =>
		  COMMENT (pr_ls ls) :: 
		  foldr (fn (alloc,C) => force_reset_aux_region(alloc,tmp_reg1,size_ff,C)) C regions_for_resetting
	   | LS.CCALL{name,args,rhos_for_result,res} => 
		  COMMENT (pr_ls ls) :: 
		  (* Note that the prim names are defined in BackendInfo! *)
		  (case (name,rhos_for_result@args,res) of
		     ("__equal_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])      => cmpi(EQUAL,x,y,d,C)
		   | ("__minus_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])      => SUBO{cond=NEVER,r1=x,r2=y,t=d} :: maybe_tag_integers(LDO{d="1",b=d,t=d},C)
		   | ("__plus_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])       => ADDO{cond=NEVER,r1=x,r2=y,t=d} :: maybe_tag_integers(LDO {d="-1",b=d,t=d},C)
		   | ("__mul_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])        => muli(x,y,d,C)
		   | ("__neg_int",[SS.PHREG_ATY x],[SS.PHREG_ATY d])                       => negi(x,d,C)
		   | ("__abs_int",[SS.PHREG_ATY x],[SS.PHREG_ATY d])                       => absi(x,d,C)
		   | ("__less_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])       => cmpi(LESSTHAN,x,y,d,C)
		   | ("__lesseq_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])     => cmpi(LESSEQUAL,x,y,d,C)
		   | ("__greater_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])    => cmpi(GREATERTHAN,x,y,d,C)
		   | ("__greatereq_int",[SS.PHREG_ATY x,SS.PHREG_ATY y],[SS.PHREG_ATY d])  => cmpi(GREATEREQUAL,x,y,d,C)
		   | ("__plus_float",[b,x,y],[d])     => addf(x,y,b,d,size_ff,C)
		   | ("__minus_float",[b,x,y],[d])    => subf(x,y,b,d,size_ff,C)
		   | ("__mul_float",[b,x,y],[d])      => mulf(x,y,b,d,size_ff,C)
		   | ("__div_float",[b,x,y],[d])      => divf(x,y,b,d,size_ff,C)
		   | ("__neg_float",[b,x],[d])        => negf(b,x,d,size_ff,C)
		   | ("__abs_float",[b,x],[d])        => absf(b,x,d,size_ff,C)
		   | ("__less_float",[x,y],[d])       => cmpf(LESSTHAN,x,y,d,size_ff,C)
		   | ("__lesseq_float",[x,y],[d])     => cmpf(LESSEQUAL,x,y,d,size_ff,C)
		   | ("__greater_float",[x,y],[d])    => cmpf(GREATERTHAN,x,y,d,size_ff,C)
		   | ("__greatereq_float",[x,y],[d])  => cmpf(GREATEREQUAL,x,y,d,size_ff,C)
		   | ("__fresh_exname",[],[aty]) =>
		       load_label_addr(exn_counter_lab,SS.PHREG_ATY tmp_reg1,size_ff,
				       LDW{d="0",s=Space 0,b=tmp_reg1,t=tmp_reg2} ::
				       move_reg_into_aty(tmp_reg2,aty,size_ff,
							 ADDI {cond=NEVER, i="1", r=tmp_reg2, t=tmp_reg2} ::
							 STW {r=tmp_reg2, d="0", s=Space 0, b=tmp_reg1} :: C))
		   | _ => 
		       (case res of
			  [] => compile_c_call_prim(name,rhos_for_result@args,NONE,size_ff,tmp_reg1,C)
			| [res_aty] => compile_c_call_prim(name,rhos_for_result@args,SOME res_aty,size_ff,tmp_reg1,C)
			| _ => die "CCall with more than one result variable")))
      in
	foldr (fn (ls,C) => CG_ls(ls,C)) C lss
      end

    (* printing a label *)
    fun debug_label(lab,C) = C
(*      if Flags.is_on "debug_codeGen" then
      let
	val lab_str = pp_lab lab ^ "\n"
	val string_lab = gen_string_lab lab_str
      in
	COMMENT "Start of debug label" ::
	load_label_addr(string_lab,SS.PHREG_ATY arg0,0,
			compile_c_call_prim("printString",[SS.PHREG_ATY arg0],NONE,0,tmp_reg0(*not used*),
					    COMMENT "End of Debug Label" :: C))
      end
      else C*)

    fun CG_top_decl' gen_fn (lab,cc,lss) = 
      let
	val size_ff = CallConv.get_frame_size cc
	val size_ccf = CallConv.get_ccf_size cc
	val size_rcf = CallConv.get_rcf_size cc
	val size_cc = CallConv.get_cc_size cc
	val C = base_plus_offset(sp,WORDS(~size_ff-size_ccf),sp,
				 LDWM{d="-4",s=Space 0,b=sp,t=tmp_reg1} ::
				 META_BV{n=false,x=Gen 0,b=tmp_reg1}::[])
      in
	gen_fn(lab,
	       LABEL(MLFunLab lab) ::
	       debug_label (MLFunLab lab,
			    base_plus_offset(sp,WORDS(size_ff),sp,
					     CG_lss(lss,size_ff,size_cc,size_rcf,size_ccf,C))))
      end

    fun CG_top_decl(LS.FUN(lab,cc,lss)) = CG_top_decl' FUN (lab,cc,lss)
      | CG_top_decl(LS.FN(lab,cc,lss)) = CG_top_decl' FN (lab,cc,lss)

    (*********************************************************)
    (* Init, Static Data and Exit Code for this program unit *)
    (*********************************************************)
    fun static_data() = DOT_DATA :: get_static_data([DOT_IMPORT (NameLab "$global$", "DATA"),
						     DOT_END])
    fun init_hppa_code() = DOT_CODE :: []
    fun exit_hppa_code () = get_lib_functions([])
  in
    fun CG {main_lab:label,
	    code=ss_prg: (StoreTypeCO,offset,AtySS) LinePrg,
	    imports:label list * label list,
	    exports:label list * label list,
	    safe:bool} =
      let
	val _ = chat "[Code Generation..."
	val _ = reset_static_data()
	val _ = reset_label_counter()
	val _ = reset_lib_functions()
	val _ = add_static_data (map (fn lab => DOT_IMPORT(MLFunLab lab, "CODE")) (#1 imports))
	val _ = add_static_data (map (fn lab => DOT_IMPORT(DatLab lab, "DATA")) (#2 imports))
	val _ = add_static_data (map (fn lab => DOT_EXPORT(MLFunLab lab, "CODE")) (main_lab::(#1 exports))) 
	val _ = add_static_data (map (fn lab => DOT_EXPORT(DatLab lab, "CODE")) (#2 exports)) 
	val _ = add_static_data [DOT_IMPORT(exn_ptr_lab, "DATA"),DOT_IMPORT(exn_counter_lab,"DATA")]
	val hp_parisc_prg = HppaResolveJumps.RJ{top_decls = foldr (fn (func,acc) => CG_top_decl func :: acc) [] ss_prg,
						init_code = init_hppa_code(),
						exit_code = exit_hppa_code(),
						static_data = static_data()}
	val _ = 
	  if Flags.is_on "print_HP-PARISC_program" then
	    display("\nReport: AFTER CODE GENERATION(HP-PARISC):", HpPaRisc.layout_AsmPrg hp_parisc_prg)
	  else
	    ()
	val _ = chat "]\n"
      in
	hp_parisc_prg
      end

    (* ------------------------------------------------------------------------------ *)
    (*              Generate Link Code for Incremental Compilation                    *)
    (* ------------------------------------------------------------------------------ *)
    fun generate_link_code (linkinfos:label list) =
      let	
	val _ = reset_static_data()
	val _ = reset_label_counter()
	val _ = reset_lib_functions()

	val global_region_labs = [BI.toplevel_region_withtype_top_lab,
				  BI.toplevel_region_withtype_string_lab,
				  BI.toplevel_region_withtype_real_lab]
	val lab_exit = NameLab "__lab_exit"
	val next_prog_unit = Labels.new_named "next_prog_unit"
	val progunit_labs = map MLFunLab linkinfos

	fun slot_for_datlab(l,C) =
	  DOT_DATA ::
	  DOT_ALIGN 4 ::
	  DOT_EXPORT(DatLab l, "DATA") ::
	  LABEL (DatLab l) ::
	  DOT_WORD "0" :: C
	fun slots_for_datlabs(l,C) = foldr slot_for_datlab C l
	fun add_progunits(l,C) = foldr (fn (lab,C) => DOT_IMPORT(MLFunLab lab,"CODE") :: C) C l

	fun toplevel_handler C =
	  let
	    val (clos_lv,arg_lv) = CallConv.handl_arg_phreg()
	    val (clos_reg,arg_reg) = (lv_to_reg clos_lv,lv_to_reg arg_lv)
	  in
	    LABEL (NameLab "TopLevelHandlerLab") ::
	    load_indexed(arg_reg,arg_reg,WORDS 0, 
	    load_indexed(arg_reg,arg_reg,WORDS 1, (* Fetch pointer to exception string *)
	    compile_c_call_prim("uncaught_exception",[SS.PHREG_ATY arg_reg],NONE,0,tmp_reg1,C)))
	  end

	fun raise_insts C = (* expects exception value in arg0 *)
	  let
	    val _ = add_static_data [DOT_EXPORT(NameLab "raise_exn","CODE")]
	    val (clos_lv,arg_lv) = CallConv.handl_arg_phreg()
	    val (clos_reg,arg_reg) = (lv_to_reg clos_lv,lv_to_reg arg_lv)
	  in
	    LABEL (NameLab "raise_exn") ::
	    COPY{r=arg0,t=arg_reg} :: (* We assume that arg_reg is preserved across C calls *)
	    
	    COMMENT "DEALLOCATE REGIONS UNTIL" ::
	    load_from_label(exn_ptr_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,0,
	    compile_c_call_prim("deallocateRegionsUntil",[SS.PHREG_ATY tmp_reg1],NONE,0,tmp_reg1,

	    COMMENT "RESTORE EXN PTR" ::
	    load_from_label(exn_ptr_lab,SS.PHREG_ATY tmp_reg1,tmp_reg1,0,
            load_indexed(tmp_reg2,tmp_reg1,WORDS(~2),
	    store_in_label(SS.PHREG_ATY tmp_reg2,exn_ptr_lab,tmp_reg2,0,

	    COMMENT "RESTORE SP AND PUSH RETURN LAB" ::
            load_indexed(sp,tmp_reg1,WORDS(~1),        (* Restore sp *)
	    load_indexed(tmp_reg2,tmp_reg1,WORDS(~4),  (* Push Return Lab *)
	    STWM{r=tmp_reg2,d="4",s=Space 0,b=sp} ::

	    COMMENT "JUMP TO HANDLE FUNCTION" ::
	    load_indexed(clos_reg,tmp_reg1,WORDS(~3), (* Fetch Closure into Closure Argument Register *)
	    LDW{d="0",s=Space 0,b=clos_reg,t=tmp_reg2} ::
	    META_BV{n=false,x=Gen 0,b=tmp_reg2}::C))))))))
	  end

	(* primitive exceptions *)
	fun setup_primitive_exception((n,exn_string,exn_lab,exn_flush_lab),C) =
	  let
	    val string_lab = gen_string_lab exn_string
	    val _ = add_static_data [DOT_DATA,
				     DOT_ALIGN 4,
				     DOT_EXPORT (exn_lab, "DATA"),
				     LABEL exn_lab,
				     DOT_WORD "0", (*dummy for pointer to next word*)
				     DOT_WORD (int_to_string n),
				     DOT_WORD "0"  (*dummy for pointer to string*),
				     DOT_DATA,
				     DOT_ALIGN 4,
				     DOT_EXPORT (exn_flush_lab, "DATA"),
				     LABEL exn_flush_lab, (* The Primitive Exception is Flushed at this Address *)
				     DOT_WORD "0"]
	  in
	    COMMENT ("SETUP PRIM EXN: " ^ exn_string) :: 
	    load_label_addr(exn_lab,SS.PHREG_ATY tmp_reg0,0,
			    ADDI{cond=NEVER,i="4",r=tmp_reg0,t=tmp_reg1} ::
			    STW{r=tmp_reg1,d="0",s=Space 0,b=tmp_reg0} ::
			    load_label_addr(string_lab,SS.PHREG_ATY tmp_reg1,0,
					    STW{r=tmp_reg1,d="8",s=Space 0,b=tmp_reg0} ::
					    load_label_addr(exn_flush_lab,SS.PHREG_ATY tmp_reg1,0, (* Now flush the exception *)
							    STW{r=tmp_reg0,d="0",s=Space 0,b=tmp_reg1} :: C)))
	  end
	val primitive_exceptions = [(0, "Match", NameLab "exn_MATCH", DatLab BI.exn_MATCH_lab),
				    (1, "Bind", NameLab "exn_BIND", DatLab BI.exn_BIND_lab),
				    (2, "Overflow", NameLab "exn_OVERFLOW", DatLab BI.exn_OVERFLOW_lab),
				    (3, "Interrupt", NameLab "exn_INTERRUPT", DatLab BI.exn_INTERRUPT_lab),
				    (4, "Div", NameLab "exn_DIV", DatLab BI.exn_DIV_lab)]
	val initial_exnname_counter = 5

	fun init_primitive_exception_constructors_code C = 
	  foldl (fn (t,C) => setup_primitive_exception(t,C)) C primitive_exceptions

	val static_data = 
	  slots_for_datlabs(global_region_labs,
			    add_progunits(linkinfos,
					  DOT_EXPORT (NameLab "code", "ENTRY,PRIV_LEV=3") ::
					  DOT_DATA ::
					  DOT_IMPORT (NameLab "$global$", "DATA") ::

					  LABEL exn_counter_lab :: (* The Global Exception Counter *)
					  DOT_WORD (int_to_string initial_exnname_counter) ::
					  DOT_EXPORT (exn_counter_lab, "DATA") ::

					  LABEL exn_ptr_lab :: (* The Global Exception Pointer *)
					  DOT_WORD "0" ::
					  DOT_EXPORT(exn_ptr_lab, "DATA") ::

					  DOT_END :: []))
	val _  = add_static_data static_data

	fun generate_jump_code_progunits(progunit_labs,C) = 
	  foldr (fn (l,C) => 
		 let
		   val next_lab = new_local_lab "next_progunit_lab"
		 in
		   COMMENT "PUSH NEXT LOCAL LABEL" ::
		   load_label_addr(next_lab,SS.PHREG_ATY tmp_reg1,0,
		   STWM{r=tmp_reg1,d="4",s=Space 0,b=sp} ::
		   COMMENT "JUMP TO NEXT PROGRAM UNIT" ::
		   META_B{n=false,target=l} :: 
                   LABEL next_lab :: C)
		 end) C progunit_labs

	val _ = add_lib_function "allocateRegion"
	fun allocate_global_regions(region_labs,C) = 
	  foldl (fn (lab,C) => 
		 COPY{r=sp, t=arg0} ::
		 LDO {d=(Int.toString(BI.size_of_reg_desc()*4)),b=sp,t=sp} ::
		 align_stack(META_BL{n=false,target=NameLab "allocateRegion",rpLink=rp,callStr="ARGW0=GR, RTNVAL=GR"} ::
			     restore_stack(store_in_label(SS.PHREG_ATY ret0,DatLab lab,tmp_reg1,0,C)))) C region_labs

	fun init_insts C =
	  DOT_CODE ::
	  LABEL (NameLab "code") ::
	  DOT_PROC ::
	  DOT_CALLINFO "CALLS, FRAME=0, SAVE_RP, SAVE_SP, ENTRY_GR=18" ::
	  DOT_ENTRY ::

	  (* Allocate global regions and push them on stack *)
	  COMMENT "Allocate global regions and push them on the stack" ::
	  allocate_global_regions(global_region_labs,

	  (* Initialize primitive exceptions *)
          init_primitive_exception_constructors_code(

	  (* Push top-level handler on stack *)
          COMMENT "PUSH TOP-LEVEL HANDLER ON STACK" ::
	  COPY{r=sp, t=tmp_reg1} ::
	  load_label_addr(NameLab "TopLevelHandlerLab", SS.PHREG_ATY tmp_reg3,0,
	  STWM{r=tmp_reg3,d="4",s=Space 0,b=sp} ::
	  STWM{r=tmp_reg1,d="4",s=Space 0,b=sp} :: (* Push TopLevelHandlerClosure *)
	  load_label_addr(exn_ptr_lab,SS.PHREG_ATY tmp_reg1,0,
	  LDW{d="0",s=Space 0,b=tmp_reg1,t=tmp_reg2} ::
	  STWM{r=tmp_reg2,d="4",s=Space 0,b=sp} ::
	  LDO{d="4",b=sp,t=sp} ::
	  STW{r=sp,d="-4",s=Space 0,b=sp} ::  
	  STW{r=sp,d="0",s=Space 0,b=tmp_reg1} :: (* Update exnPtr *)

	  (* Double Align SP *)	
          COMMENT "DOUBLE ALIGN SP" ::
	  LDI{i="4",t=tmp_reg1} :: 
          AND{cond=EQUAL,r1=tmp_reg1,r2=sp,t=tmp_reg1} ::
          LDO{d="4",b=sp,t=sp} ::

	  (* Code that jump to progunits. *)
	  COMMENT "JUMP CODE TO PROGRAM UNITS" ::
	  generate_jump_code_progunits(progunit_labs,
          (* Jump to lab_exit *)
          COMMENT "JUMP TO LAB_EXIT" ::
          META_B{n=false,target=lab_exit} :: C)))))
	  
	fun lab_exit_insts C =
	  let val res = if !BI.tag_values then 1 (* 2 * 0 + 1 *)
			else 0
	  in
	    LABEL(lab_exit) ::
	    COMMENT "**** Link Exit code ****" ::
	    compile_c_call_prim("terminate", [SS.INTEGER_ATY res], NONE,0,tmp_reg0(*not used*),
				DOT_EXIT :: 
				DOT_PROCEND :: C)
	  end

	val init_link_code = init_insts(lab_exit_insts(raise_insts(toplevel_handler [])))
      in
	HppaResolveJumps.RJ{top_decls = [],
			    init_code = init_link_code,
			    exit_code = get_lib_functions [],
			    static_data = get_static_data []}
      end
  end


  (* ------------------------------------------------------------ *)
  (*  Emitting Target Code                                        *)
  (* ------------------------------------------------------------ *)
  fun emit(prg: AsmPrg,filename: string) : unit = 
    let 
      val os = TextIO.openOut filename
    in 
      HpPaRisc.output_AsmPrg(os,prg);
      TextIO.closeOut os;
      TextIO.output(TextIO.stdOut, "[wrote HP code file:\t" ^ filename ^ "]\n")
    end 
  handle IO.Io {name,...} => Crash.impossible ("HppaKAMBackend.emit:\nI cannot open \""
					       ^ filename ^ "\":\n" ^ name)
end;



(*    fun in_bytes(BYTES x) = x
      | in_bytes(WORDS x) = x*4
      | in_bytes(IMMED x) =
      if Int.mod(x,8) <> 0 then
	die ("in_bytes: " ^ int_to_string x ^ " cannot be converted into bytes")
      else
	Int.div(x,8)*)

(*    fun in_words(BYTES x) =
      if Int.mod(x,4) <> 0 then
	die ("in_words: Bytes " ^ int_to_string x ^ " cannot be converted into words")
      else
	Int.div(x,4)
      | in_words(WORDS x) = x
      | in_words(IMMED x) =
	if Int.mod(x,32) <> 0 then
	  die ("in_words: Immed " ^  int_to_string x ^ " cannot be converted into words")
	else
	  Int.div(x,32)*)
	  
(*    fun in_immeds(BYTES x) = x * 8
      | in_immeds(WORDS x) = x * 32
      | in_immeds(IMMED x) = x*)

(*    fun resolve_aty_use(SS.REG_I_ATY offset,t,size_ff,C) = (t,calc_offset(sp,BYTES(~size_ff*4+offset*4+inf_bit),t,C))
      | resolve_aty_use(SS.REG_F_ATY offset,t,size_ff,C) = (t,calc_offset(sp,BYTES(~size_ff*4+offset*4),t,C))
      | resolve_aty_use(SS.STACK_ATY offset,t,size_ff,C) = (t,load_word(t,sp,BYTES(~size_ff*4+offset*4),C))
      | resolve_aty_use(SS.DROPPED_RVAR_ATY,t,size_ff,C) = (t,C)
      | resolve_aty_use(SS.PHREG_ATY phreg,t,size_ff,C)  = (phreg,C)      
      | resolve_aty_use(SS.INTEGER_ATY i,t,size_ff,C)    = (t,load_immed(IMMED i,t,C))
      | resolve_aty_use(SS.UNIT_ATY,t,size_ff,C)         = (t,load_immed(IMMED ml_unit,t,C))*)
