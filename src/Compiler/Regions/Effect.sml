(*$Effect: DIGRAPH PRETTYPRINT REPORT CRASH EFFECT FLAGS OrderFinMap*)

functor Effect(structure G: DIGRAPH
               structure Crash: CRASH
               structure Report: REPORT
               structure Flags: FLAGS
               structure PP: PRETTYPRINT
                sharing type PP.StringTree = G.StringTree): EFFECT =  (* comment out this signature before 
                                                                         running TestEffect *)

(* effect1.sml: added run-time region types *)

struct

  (* Add some dynamic flags for pretty-printing region variables. *) 
  
  val add_entry = fn (s, s', r) => Flags.add_flag_to_menu (["Layout"], s, s', r)
  val print_rho_levels = ref true
  val print_rho_types = ref true
  val entries = [("print_rho_levels", "print levels of region variables", print_rho_levels),
		 ("print_rho_types", "print runtime types of region variables", print_rho_types)]
  val _ = List.apply add_entry entries


  type StringTree = PP.StringTree
  infix footnote
  fun x footnote y = x
  fun die s = Crash.impossible("Effect." ^ s)
  fun log_tree(tr: StringTree) = PP.outputTree(fn s => output(!Flags.log, s), tr, !Flags.colwidth)
  fun log_string  s = output(!Flags.log, s ^ "\n")

  fun noSome(None, s) = die s
    | noSome(Some v, _) = v

  datatype runType = WORD_RT | STRING_RT | REAL_RT | TOP_RT | BOT_RT

  fun ord_runType WORD_RT = 0
    | ord_runType STRING_RT = 1
    | ord_runType REAL_RT = 2
    | ord_runType TOP_RT = 3
    | ord_runType BOT_RT = 4

  fun is_wordsize WORD_RT = true
    | is_wordsize _ = false

  fun show_runType tau =
      case tau of 
           WORD_RT => "w"
         | REAL_RT => "r"
         | STRING_RT => "s"
         | TOP_RT => "t"
         | BOT_RT => "b"

  fun lub_runType(rt1,rt2) = 
      if rt1 = rt2 then rt1
      else if rt1 = BOT_RT then rt2
      else if rt2 = BOT_RT then rt1
      else if rt1 = WORD_RT orelse rt2 = WORD_RT 
           then die "cannot unify word runtype region with other region"
      else TOP_RT

  type key = int ref (* for printing and sorting of nodes *)
  fun show_key(ref i) = Int.string i
  fun layout_key(r) = PP.LEAF(show_key r)

  fun key_lt(ref i, ref (j:int)) = i<j

  fun show_key(ref i ) = Int.string i

  type level = int ref (* for stratification of cones *)
  fun show_level(ref i ) = Int.string i
  fun layout_level(l) = PP.LEAF(show_level l)


  (* info in nodes of effect graphs *)
  datatype einfo = EPS of {key: key, level:  level, 
                           represents: einfo G.node list Option, 
                           instance : einfo G.node Option ref,
                           pix: int ref}
                 | UNION of {represents: einfo G.node list Option}
                 | PUT | GET  
                 | RHO of {put: einfo G.node Option,
                           get: einfo G.node Option,
                           key: key,
                           level: level,
                           instance : einfo G.node Option ref,
                           pix : int ref,      (* pre-order index; for normalised type schemes *)
                           ty : runType}
  
  fun layout_einfo(einfo) = case einfo of
        EPS{key,level,...} => PP.LEAF("e"^ show_key key 
                            (* ^ "(" ^ show_level level ^ ")" *)   )
      | PUT   => PP.LEAF "put"
      | GET   => PP.LEAF "get"
      | UNION _=> PP.LEAF "U"
      | RHO{key, level,ty,...} => 
	  PP.LEAF ("r" ^ show_key key ^ 
		   (if !print_rho_types then show_runType ty
		    else "") ^ 
		   (if !print_rho_levels then "(" ^ show_level level ^ ")" 
		    else ""))

  fun transparent(UNION _) = true
    | transparent _     = false

  type effect = einfo G.node 
  type place = effect
  val empty = G.mk_node (UNION{represents = None})

  fun layout_effect e = G.layout_node layout_einfo (G.find e)
  fun layout_effect_deep e = G.layout_nodes_deep layout_einfo [G.find(e)]
  
  fun get_instance effect =
     case G.find_info (G.find effect) of
       EPS{instance, ...} => instance
     | RHO{instance, ...} => instance
     | _ => die ".get_instance"

  fun is_arrow_effect effect =  (* effect node not necessarily canonical *)
     case G.find_info  effect of
       EPS _ => true
    | _ => false

  fun is_rho effect =
     case G.find_info effect of (* effect node not necessarily canonical *)
       RHO _ => true
    | _ => false

  fun is_put effect =           (* effect node not necessarily canonical *)
     case G.find_info effect of
       PUT => true
    | _ => false

  fun is_get effect =
     case G.find_info effect of
       GET => true
    | _ => false

  fun is_put_or_get effect = 
     case G.find_info effect of
       GET => true
     | PUT => true
     | _ => false

  fun get_level_and_key(effect): (level*key) Option =
     case G.find_info (G.find effect) of
       EPS{level, key,...} => Some(level,key)
     | RHO{level, key,...} => Some(level,key)
     | _ => None

  fun key_of_rho(effect): int =
     case G.find_info (effect) of
      RHO{key,...} => !key
     | _ => die "key_of_rho (not a RHO)"

  fun get_level_and_key'(effect): (level*key) Option = (* effect canonical *)
     case G.get_info (effect) of
       EPS{level, key,...} => Some(level,key)
     | RHO{level, key,...} => Some(level,key)
     | _ => None

  fun setkey generator (effect) =
     case G.get_info(G.find effect) of
       EPS{key, ...} => key:= generator()
     | RHO{key, ...} => key:= generator()
     | _ => ()

  fun get_level_of_rho(effect):int =
     case G.find_info (effect) of
       RHO{level as ref (l),...} => l
     | _ => die "GetLevelOfRho"

  fun get_key_of_eps(effect):int =
     case G.find_info (effect) of
       EPS{key as ref (k),...} => k
     | _ => die "GetKeyOfEps"

  fun get_place_ty(effect): runType Option =
     case G.find_info (effect) of
      RHO{ty,...} => Some ty
     | _ => None

  fun level_of(effect) : int Option =
     case G.find_info (effect) of
       EPS{level, key,...} => Some(!level)
     | RHO{level, key,...} => Some(!level)
     | _ => None

  fun edge(from,to) = G.mk_edge(from,to);

  fun mkRho(level, key) = 
       G.mk_node(RHO{key = ref key, level = ref level, 
                     put = None, get = None, instance = ref None, pix = ref ~1, ty = BOT_RT})
  
  fun mkPut(n: effect) = (* n must represent a region variable*)
      let val n = G.find n
      in
       case G.get_info n of
         RHO{put = Some n',...} => n'  (* hash consing *)
       | RHO{put = None, key, level,get,instance,pix,ty} =>
           let (* create new node *)
               val new = G.mk_node(PUT)
           in G.set_info n (RHO{put = Some new, 
                                get = get, key = key, level = level, instance = instance, pix=pix,ty =ty});
              G.mk_edge(new,n);
              new
           end
       | _ => die "mkPut: node does not represent region variable"
      end

  fun mkGet(n: effect) = (* n must represent a region variable*)
      let val n = G.find n
      in
       case G.get_info n of
         RHO{get = Some n',...} => n'  (* hash consing *)
       | RHO{get = None, key, level,put,instance,pix,ty} =>
           let (* create new node *)
               val new = G.mk_node(GET)
           in G.set_info n (RHO{get = Some new, 
                                put = put, key = key, level = level, instance=instance, pix=pix,ty=ty});
              G.mk_edge(new,n);
              new
           end
       | _ => die "mkGet: node does not represent region variable"
      end

  fun mkUnion(l : effect list) =
      let 
          val new = G.mk_node(UNION{represents=None})
      in
          List.apply (fn n => G.mk_edge(new, G.find n)) l;
          new
      end

  fun mkEps(level,key) = G.mk_node(EPS{key = ref key, level = ref level, represents = None, pix = ref ~1, instance = ref None})

  fun find node = G.find node

(*
  fun remove_duplicates effects =
    let fun loop([], acc) = acc
          | loop(effect::rest, acc) =
              let val r = (G.get_visited effect)
              in if !r then loop(rest,acc)
                 else (r:= true; loop(rest, effect::acc))
              end

        val effects = map find effects
    in
        loop(effects,[])
          footnote List.apply (fn node => G.get_visited node:= false) effects
    end
*)

  fun remove_duplicates effects =
    let fun loop([], acc) = acc
          | loop(effect::rest, acc) =
              let val effect = find effect
                  val r = (G.get_visited effect)
              in if !r then loop(rest,acc)
                 else (r:= true; loop(rest, effect::acc))
              end

        val result = loop(effects,[])
    in
        List.apply (fn node => G.get_visited node:= false) result;
        result
    end

  (*********************************)
  (*     cones                     *)
  (*********************************)

  (* A cone is a finite map from an initial segment of the natural numbers
     to finite maps, which map node keys to nodes *)

  structure ConeLayer(*:ORDER_FINMAP*) = 
      struct
        structure Array = NewJersey.Array
        val lsize  = 10
         infix eq
     
         type dom = int
     
         (* The balance of a tree is 'L', if the left subtree is one
            deeper than the right subtree, 'B' if the left and right subtrees
            have the same depth, and 'R' if the right subtree is one deeper than
            the left subtree: *)
     
         type 'b map = (int*'b)list array
     
         val empty = Array.array(lsize,[]:(int*effect)list)
         fun mkEmpty() = Array.array(lsize,[])
     
         fun lookup t key =
           let 
             fun loop [] = None
               | loop ((key',y)::rest) = if key = key' then Some y else loop rest
           in 
             loop(Array.sub(t,key mod lsize))
           end
     
     
         fun add(k0,d0, t) =
          let val i = k0 mod lsize
              val l = Array.sub(t,i)
          in Array.update(t, i, (k0,d0)::l); t
          end
     
     
         fun remove(k0, t) = 
          let val i = k0 mod lsize
              val l' = List.all (fn (i',_) =>i'<>i)(Array.sub(t,i))
          in 
              Array.update(t, i, l');
              General.OK t
          end handle _ => General.Fail "element not found" 
     
         fun range (m:'b map) : 'b list =
           let
             fun  loop(n, acc) = if n<0 then acc
                  else loop(n-1, Array.sub(m, n) @ acc)
           in
        	map (fn (x,y) => y) (loop(lsize-1,[]))
           end
     
         fun list (m:'b map) : (dom * 'b) list =
           let
             fun  loop(n, acc) = if n<0 then acc
                  else loop(n-1, Array.sub(m, n) @ acc)
           in
        	loop(lsize-1,[])
           end
     
     
         fun fromSortedList l a=
           List.foldL (fn (d,r) => fn a => add(d,r, a)) a l
     
         type StringTree = PP.StringTree
     
         fun layoutMap {start, eq=equal, sep, finish} layoutDom layoutRan m =
           PP.NODE {start=start,
     	       finish=finish,
     	       children=map (fn (d,r) => 
     			     PP.NODE {start="",
     				      finish="",
     				      children=[layoutDom d, 
     						layoutRan r],
     				      indent=3,
     				      childsep=PP.RIGHT equal})
     	       (list m),
     	       indent=3,
     	       childsep=PP.RIGHT sep}
     
         type Report = Report.Report
     
        fun reportMap f t = Report.flatten(map f (list t))
     
         val reportMapSORTED  = reportMap


      end


  type coneLayer = effect ConeLayer.map

  (* The Cone is implemented as an array, which
     represents a stack of coneLayers *)

  structure Cone: sig 
                     type map  (* = coneLayer map *)
                     type cone
                     val max_cone_level: int
                     val empty:  map
                     val lookup: map -> int -> coneLayer Option
                     val add: int * coneLayer * map -> map
                     val remove: int * map -> (map, string)General.Result
                     val layoutMap: {start: string, eq: string, sep: string, finish: string} ->
                         (int -> StringTree) -> 
                         (coneLayer -> StringTree) ->  cone -> StringTree
                     val reset: cone -> unit
                  end =
  struct
    local open NewJersey.Array
    in
       val max_cone_level = 1000
       type map = coneLayer array
       type cone = int * (*coneLayer*) map
     (* The integer is the number of levels in the cone;
        initially 0 *)
       val global_array:map  = array(max_cone_level, ConeLayer.empty)
       val empty = global_array
       fun lookup _ i = Some(sub(global_array, i))
                    handle _ => None
       fun add(i,coneLayer,_) = 
          (update(global_array, i, coneLayer)
                    handle _ => die ("Cone.add: index " 
                                     ^ Int.string i 
                                     ^ "out of range [0.." 
                                     ^ Int.string (i-1) ^ "]\n");
           global_array)
     
       fun remove(i,_) =
          (update(global_array, i, ConeLayer.empty);
           General.OK global_array)
           handle _ => General.Fail ("Cone.remove: index " 
                                     ^ Int.string i 
                                     ^ "out of range [0.." 
                                     ^ Int.string (i-1) ^ "]\n")
    
       fun reset (_,array) =      (* reset levels 0 to max_cone_level -1 in array *)
	 let fun reset_loop(i) =
	       if i>= max_cone_level then ()
	       else (update(array, i, ConeLayer.empty);
		     reset_loop(i+1))
	 in reset_loop 0
	 end

       fun layoutMap {start: string, eq: string, sep: string, finish: string}
                     layoutInt
                     layoutConeLayer
                     cone =
         let
            val (n, table) = cone
            fun get_layers(i) = 
                  if i> n then []
                  else (i,sub(table, i)) :: get_layers(i+1)
         in
            PP.NODE{start = start, finish = finish,  indent = 3, childsep=PP.RIGHT sep,
                    children= map (fn (d,r) => 
			     PP.NODE {start="",
				      finish="",
				      children=[layoutInt d, 
						layoutConeLayer r],
				      indent=3,
				      childsep=PP.RIGHT sep})
                                  (get_layers(1))}
         end
    end
  end

  type cone = Cone.cone
  fun level((i,_):cone) = i
  val emptyLayer = ConeLayer.empty
  val emptyCone = (0,Cone.empty)
  fun layoutLayer (layer: coneLayer) : PP.StringTree= 
      ConeLayer.layoutMap{start = "{", finish = "}", eq = "=", sep = ","}
                         ( PP.LEAF o Int.string)
                         layout_effect_deep
                         layer
  fun layoutLayerRng (layer: coneLayer): PP.StringTree =
      let val rng_without_duplicates = remove_duplicates (ConeLayer.range layer)
      in
          PP.HNODE{start = " ", finish = "", childsep = PP.RIGHT", ", 
                   children = map layout_effect_deep rng_without_duplicates}
      end

  fun layoutCone (cone:cone) : PP.StringTree =
      Cone.layoutMap{start = "{", finish = "}\n", eq = "=", sep = ","}
                         (fn i: int => PP.LEAF("level " ^ Int.string i))
                         layoutLayer
                         (cone)

  (* remove "effect" with "key" from "cone" at "level" *)

  fun remove(effect, level, key, cone as (n, c)): cone=
       case Cone.lookup c (!level) of
         None => die "remove: (no such level in cone)"
       | Some layer => (case ConeLayer.remove(key,layer) of
           General.OK layer' => (n,Cone.add(!level,layer',c)) 
                                    (* replaces old layer*)
         | _ => die "remove: (no such key in cone)")

  (* add "effect" with "key" to "cone" at "level" *)

  fun add(effect, level:int, key:int, cone as (n,c)): cone =
       case Cone.lookup c level of
         None => die ("add: (no such level in cone): " ^ Int.string level)
       | Some layer => 
           (n,Cone.add(level, ConeLayer.add(key,effect,layer), c)) 
                                   (* replaces old layer*)


  (* push(cone):   start a new level on top of cone *)

  fun push(cone as (n,c):cone): cone = (n+1, Cone.add(n+1,ConeLayer.mkEmpty(), c))

  (* sort: effect list -> effect list
     l' = sort(l):
     l is a list of effects without duplicates, 
     each of which is a region variable or an effect variable;
     l' is l, sorted in descending order on keys *)

  exception Take and Drop

  fun take(0, _ ) = []
    | take(n, x::xs) = x::take(n-1, xs)
    | take(n, []) = raise Take

  fun drop(0, l) = l
    | drop(n, x::xs) = drop(n-1, xs)
    | drop(n, []) = raise Drop

  fun lt_eps_or_rho(eps_or_rho1, eps_or_rho2) = 
    case (get_level_and_key eps_or_rho1, get_level_and_key eps_or_rho2) of
          (Some(_, ref x'), Some(_, ref y')) => x' < y'
    | _ => die "lt_eps_or_rho"

  fun merge([], ys) = ys:effect list
    | merge(xs, []) = xs
    | merge(l as x::xs, r as y:: ys) =
       (case (get_level_and_key x, get_level_and_key y) of
          (Some(_, ref x'), Some(_, ref y')) =>
           if x'>= y' then x::merge(xs, r)
           else y:: merge(l, ys)
        | _ => die "merge: cannot sort effects that are neither region variables nor effect variables")

  (* sort: top-down mergesort*)

  fun sort [] = []
    | sort [x] = [x]
    | sort xs =
      let val k = length xs div 2
      in merge(sort(take(k, xs)),
               sort(drop(k, xs)))
      end

  (* pushLayer: see signature *)

  fun pushLayer(ateffects: effect list, cone as (n,c):cone): cone = 
      let val l = rev((map (fn effect => 
                          case get_level_and_key effect of
                            Some(level,key) => (level:= n+1;
                                                (! key, effect))
                          | _ => die "pushLayer: atomic effect neither region- nor effect variable")
                              ateffects))
          fun is_sorted [] = true
            | is_sorted [x] = true
            | is_sorted ((i:int,_)::(j,y):: rest) = 
                 i<j andalso is_sorted ((j,y)::rest)
          val _ = if is_sorted l then () else die "pushLayer: atomic effects not not sorted"
          val layer = ConeLayer.fromSortedList l (ConeLayer.mkEmpty())
      in
          (n+1, Cone.add(n+1, layer, c))
      end


  (* pop topmost layer of cone *)

  fun pop((n,c):cone): coneLayer * cone =
       if n<=0 then die "pop: Attempt to pop empty cone"
       else 
        let val top_layer = noSome(Cone.lookup c n, "pop: no such layer")
        in  (top_layer,
             (n-1, case Cone.remove(n,c) of
                    General.OK(c') => c'
                  | _ => Crash.impossible ("Pop of cone failed: level = " 
                                           ^ Int.string n)
             ))
        end

  (* pop topmost layer of cone and return those effects of the topmost
     level that still have the level of the topmost level as children of "effect";
     any previous out-edges of "effect" are over-written *)

  fun topLayer((n,c): cone) : effect list =
        let val top_layer = noSome(Cone.lookup c n, "topLayer: no such layer")
            val atomic_effects = (* the atomic effects in the topmost layer that have not been
                                    lowered to lower levels *)
             sort(
              remove_duplicates(
               List.all (fn eff => let val (ref l, _) = noSome (get_level_and_key eff, "popAndClean")
                                   in l>= n 
                                   end)  (ConeLayer.range top_layer)))
            
        in  
          atomic_effects
        end

  fun popAndClean(cone:cone): effect list  * cone =
      (topLayer cone, #2(pop cone))

  local
    val init_count = ref 6    (* 6 top-level predefined rhos/eps declared below! *)
    val count = ref 0
    fun inc r = r:= !r + 1;
  in
    fun resetCount _ = count:= !init_count
    fun commit_count () = init_count:= !count
    fun freshInt _ = (inc count; !count)
  end

  (* freshRho(cone): Generate a fresh region variable
     at the topmost layer of   cone   and insert it in
     this topmost layer *)

  fun freshRho(cone:cone as (n, c)): effect * cone =
      let val key = freshInt()
          val node = mkRho(n,key)
      in (node, add(node, n, key, cone))
      end

  fun insertRho rho (cone as (n,c)) = add(rho,n, key_of_rho rho, cone)
  fun insertEps eps (cone as (n,c)) = add(eps,n, get_key_of_eps eps, cone)

  fun freshRhos(rhos,c: cone): effect list * cone  = 
      List.foldR (fn rho => fn (rhos',c) => 
                  let val (rho',c) = freshRho c 
                  in (rho'::rhos',c) 
                  end) ([],c) rhos

  fun rename_rhos_aux(rhos, c: cone as (n,_), f, g) : effect list * cone =
      List.foldR (fn rho => fn (rhos',c) =>
                  case G.find_info(G.find rho) of
                    RHO{level,pix,ty,...} =>
                     let val k = freshInt()
                         val new_rho = 
                      G.mk_node(RHO{key = ref(k), level = ref(g level),
                                    put = None, get = None, instance = ref None,
                                    pix = ref(f(pix)), ty = ty})
                     in
                        (new_rho::rhos', add(new_rho, n, k, c))
                     end
                   | _ => die "renameRhos: not a region variable"
                  ) ([],c) rhos

  fun renameRhos(rhos, c: cone as (n,_)) : effect list * cone =
      rename_rhos_aux(rhos, c, fn(ref int) => int, fn (ref int) => int)

  fun cloneRhos(rhos, c: cone as (n,_)) : effect list * cone =
      rename_rhos_aux(rhos, c, fn(ref int) => ~1, fn _ => n)

  fun rename_epss_aux(epss, c: cone as (n,_), f, g) : effect list * cone =
      List.foldR (fn eps => fn (epss',c) =>
                  case G.find_info(G.find eps) of
                    EPS{level,pix,represents = None,...} =>
                     let val k = freshInt()
                         val new_eps= 
                      G.mk_node(EPS{key = ref(k), level = ref(g level),
                                    instance = ref None,
                                    represents = None,
                                    pix = ref(f(pix))})
                     in
                        (new_eps::epss', add(new_eps, n, k, c))
                     end
                   | _ => die "renameEpss: not a region variable"
                  ) ([],c) epss
  fun renameEpss(epss, c: cone as (n,_)) : effect list * cone =
      rename_epss_aux(epss,c,fn(ref int) => int, fn(ref int) => int)

  fun cloneEpss(epss, c: cone as (n,_)) : effect list * cone =
      rename_epss_aux(epss,c,fn(ref int) => ~1, fn _ => n)

  fun freshRhoWithTy(rt: runType, cone:cone as (n, c)): effect * cone =
      let val key = freshInt()
          val node =G.mk_node(RHO{key = ref key, level = ref n, 
                                  put = None, get = None, instance = ref None, pix = ref ~1, ty = rt})
        in (node, add(node, n, key, cone))
      end
  
  fun setRunType(place:effect)(rt: runType) : unit = 
    let val place = G.find place
    in
      case G.get_info(place) of
        RHO{put,get,key,level,instance,pix,ty} =>
          G.set_info place (RHO{put=put,get=get,key=key,level=level,instance=instance,pix=pix,ty = rt})
      | _ => die "setRunType: node is not a region variable"
    end

  (* freshEps(cone): Generate a fresh effect variable
     at the topmost layer of   cone   and insert it in
     this topmost layer *)

  fun freshEps(cone:cone as (n, c)): effect * cone =
      let val key = freshInt()
          val node = mkEps(n,key)
      in (node, add(node, n, key, cone))
      end

  fun freshEpss(epss, c: cone): effect list * cone = 
    List.foldR (fn eps => fn (epss',c) => 
                let val (eps',c) = freshEps c 
                in (eps'::epss',c) 
                end) ([],c) epss


  (* Toplevel regions and arrow effect *)

  val (toplevel_region_withtype_top, initCone) = freshRhoWithTy(TOP_RT,push emptyCone)
  val (toplevel_region_withtype_word, initCone) = freshRhoWithTy(WORD_RT,initCone)
  val (toplevel_region_withtype_bot, initCone) = freshRhoWithTy(BOT_RT,initCone)
  val (toplevel_region_withtype_string, initCone) = freshRhoWithTy(STRING_RT,initCone)
  val (toplevel_region_withtype_real, initCone) = freshRhoWithTy(REAL_RT,initCone)
  val (toplevel_arreff, initCone) = freshEps(initCone)

  val _ =
    let val toplevel_rhos = [toplevel_region_withtype_top, toplevel_region_withtype_word,
			     toplevel_region_withtype_bot, toplevel_region_withtype_string,
			     toplevel_region_withtype_real]
        val puts = map mkPut toplevel_rhos
        val gets = map mkGet toplevel_rhos
    in List.apply (fn to => edge(find toplevel_arreff,find to)) (puts@gets)
    end

  (* Optimization: For regions of type word we reuse 
   * the top-level region. Word regions are
   * dropped anyway. *)
  val freshRhoWithTy = fn (WORD_RT,cone) => (toplevel_region_withtype_word, cone)
                        | p => freshRhoWithTy p 



(* Tracing Cone Layers (for profiling)

  val trace = ConeLayer.trace
  fun traceOrderFinMap(): unit = 
  (* sort ConeLayer.trace and print first 50 elements *)
  let
    fun merge([], ys) = ys:int list
      | merge(xs, []) = xs
      | merge(l as x::xs, r as y:: ys) =
             if x>= y then x::merge(xs, r)
             else y:: merge(l, ys)
  
    (* sort: top-down mergesort*)
  
    fun sort [] = []
      | sort [x] = [x]
      | sort xs =
        let val k = length xs div 2
        in merge(sort(take(k, xs)),
                 sort(drop(k, xs)))
        end
    
    fun say i = output(std_out, i)
    val l = sort(!ConeLayer.trace)
    fun report[] = []
      | report(x::rest) = 
          let val (l,r) = List.splitFirst(fn y => y<>x) rest
                          handle _ => (rest,[])
          in 
              (x, List.size l +1, x * (List.size l +1))::
              report(r)
          end;
    fun report1 [] = ()
      | report1((x, multiplicity, product)::rest)=
         (say ("depth " ^ Int.string x  ^ ": " 
                  ^ Int.string(multiplicity) ^ " times = " ^
                  Int.string product ^  "\n");
          report1 rest)
    
    val l1 = report l
    val sum = List.foldL (fn x:int => fn y => x+y) 0 
              (map #3 l1)
  in
    report1 l1;
    say("\nsum = " ^ Int.string sum ^ "\n")
  end;
   
tracing *)
  (******************************************************)
  (*     computing effect increments during algorithm R *)
  (******************************************************)

  val algorithm_R = ref false

  datatype delta_phi = Lf of effect list | Br of delta_phi * delta_phi

  structure Increments = 
    OrderFinMap(structure Order = 
                  struct type T = effect
                    fun lt (i: effect) (j:effect) = 
                         get_key_of_eps i < get_key_of_eps j
                  end
                structure PP = PP
                structure Report = Report)


  val globalIncs: delta_phi Increments.map ref = ref(Increments.empty)

  fun unvisitDelta (Lf effects) = List.apply G.unvisit_all effects
    | unvisitDelta (Br(d1,d2)) = (unvisitDelta d1; unvisitDelta d2)

  fun update_increment(eff,Lf[]) = ()
    | update_increment(eff,delta_new) = 
       if is_arrow_effect eff
       then
        case Increments.lookup (!globalIncs) eff of
          Some delta => globalIncs:= Increments.add(eff,Br(delta, delta_new),!globalIncs)
        | None =>       globalIncs:= Increments.add(eff,delta_new,!globalIncs)
       else ()
                                             
  fun key_of_eps_or_rho node = case get_level_and_key(node)
       of Some(level,key) => !key | _ => die "key_of_eps_or_rho"



  fun computeIncrement delta =
    let 

        fun search' (b,[]) = b
          | search' (b,x::xs) = search'(search(x, b), xs)

        and searchDelta(Lf effects, acc) = search'(acc,effects)
          | searchDelta(Br(d1,d2), acc) = 
                 searchDelta(d1,searchDelta(d2, acc))

        and search (n: effect, ns : effect list) : effect list =
          let 
            val n = G.find n
            val r = G.get_visited n
          in
            if !r then ns 
            else (r := true;
                  let
                          val i = G.get_info n 
                  in
                          case i of
                            UNION _ =>
                                  (* do not include n itself, but search children *)
                                  (search'(ns,(G.out_of_node n)))
                           | RHO _ => (* do not include it; a PUT or GET will be
                                         included, when necessary *)
                                  ns
                           | PUT  =>  n::ns 
                           | GET  =>  n::ns
                           | EPS _  => 
                             search'(
                                    (case Increments.lookup (!globalIncs) n of
                                       Some delta' => searchDelta(delta', n::ns)
                                     | None => n::ns),
                                    (G.out_of_node n))
                                   
                  end
                 )
          end

      in
        searchDelta(delta,[]) footnote unvisitDelta delta
      end

  fun current_increment(eps) = 
        case Increments.lookup (!globalIncs) eps of
          Some delta =>  delta
        | None => Lf []

  (*****************************************************)
  (*     unification of region- and effect variables   *)
  (*****************************************************)

  (* lower: See explanation in signature;
     Lower use  a depth-first traversal  of effect. 
  *)     



  fun lower (newlevel: int) =
  let
    fun low' (b,[]) = b
      | low' (b,x::xs) = (low'(low(x, b), xs))
              
    and low (effect,(cone as (n,c):cone)): cone =
        case get_level_and_key effect of
          Some (l as ref( n:int),key) =>
            if newlevel>= n then cone
            else   (* newlevel < level: lower level *)
                   let val cone' = remove(effect,l,!key,cone) (* take 
                                      node out of cone high cone level*)
                       val _  = l:= newlevel
                       val cone'' = add(effect, newlevel, !key,cone') (* put 
                                          node back in cone at lower level*)
                   in
                       low' (cone'',G.out_of_node (G.find effect))
                   end
        | None => (* not EPS or RHO, no level; just lower children *)
             low'(cone,G.out_of_node (G.find effect))
   in 
       fn effect => fn cone => low(effect,cone)
   end

  fun lower_delta level delta B = 
    case delta of 
      Lf(l: effect list) => List.foldL (lower level) B l
    | Br(d1, d2) => lower_delta level d2 (lower_delta level d1 B)


  fun setminus(l1: effect list, l2: effect list): effect list =
     (* Computes l1 \ l2;
       First mark all nodes in l2; then select unmarked nodes from l1 (these 
       are the result). Finally, unmark all nodes in l2 *)
     let val l1 = map find l1 
         and l2 = map find l2
     in List.apply (fn node => G.get_visited node:= true) l2;
        List.all (fn node => not(!(G.get_visited node))) l1
          footnote List.apply (fn node => G.get_visited node:= false) l2
     end
  
  (* update_areff(eps) assumes that the increments recorded for eps have
     level no greater than the level of eps *)

  fun update_areff(eps) = 
   ((*say ("update_areff: eps = ");
    PP.outputTree(say, layout_effect_deep eps, !Flags.colwidth); *)
    if is_arrow_effect eps
    then 
      case Increments.lookup (!globalIncs) eps of
          Some delta => 
            let val nodes = computeIncrement delta
                val to_be_added = setminus(nodes, G.nodes(G.subgraph [eps]))
            in  G.add_edges(G.find eps, to_be_added)(*;
                say "update_areff:result = ";*)
                (*PP.outputTree(say, layout_effect_deep eps, !Flags.colwidth) *)
            end
        | None =>       ()
    else ()
   )

  fun min_key(key1 as ref i1,key2 as ref i2) = 
    if (i1:int) < i2 then key1 else key2

  (* einfo_combine(einfo1, einfo2): this function is used as argument to 
     G.union_without_edge_duplication when implementing unification of region-
     and effect variables *)

  fun einfo_combine_eps(eps1,eps2)(einfo1,einfo2) = (* assume einfo1 and einfo2 
						     * have the same level *)
    case (einfo1, einfo2) 
      of (EPS{level = l1, key = key1 as ref k1, represents, instance, pix}, 
	  EPS{level = l2, key = key2 as ref k2, ...}) => 

	if k1 = k2 then die "einfo_combine_eps: expected keys to be different"
	else (* merge increment information for einfo1 and einfo2 *)
	  
	  if k1 < k2 then
	    (if !algorithm_R then
	       case Increments.lookup(!globalIncs)eps2
		 of Some delta2 => (update_increment(eps1,delta2);
				    update_areff(eps1) handle _ => die "einfo_combine_eps1")
		  | None => ()
	     else (); einfo1)
	  else (* k2 < k1 *)
	    (if !algorithm_R then
	       case Increments.lookup(!globalIncs)eps1
		 of Some delta1 => (update_increment(eps2,delta1);
				    update_areff(eps2) handle _ => die "einfo_combine_eps2")
		  | None => ()
	     else (); einfo2)
       | _ => die "einfo_combine_eps"
 
  fun einfo_combine_rho(einfo1, einfo2) =  (* assume einfo1 and einfo2 
					    * have the same level *)
    case (einfo1, einfo2) 
      of (RHO{level = l1, put = p1, get = g1,key=k1,instance=instance1, pix = pix1,ty = t1}, 
	  RHO{level=l2,put=p2,get=g2,key=k2, instance = instance2, pix = pix2, ty = t2}) =>
	RHO{level = l1, put = aux_combine(p1,p2), 
	    get = aux_combine(g1,g2), key =min_key(k1,k2), instance = instance1, pix = pix1, ty = lub_runType(t1,t2)}
	| _ => die "einfo_combine_rho"
  and aux_combine(op1,op2) =
    case (op1,op2) of
      (None,None) => op1
    | (Some _, None) => op1
    | (None, Some _) => op2
    | (Some n1, Some n2) => 
         (* n1 and n2 are supposed to be either both PUT nodes 
            or both GET nodes *)
         (* The resulting node (a PUT/GET) will have only one out-edge,
            namely to the region variable which n1 points to *)
         Some(G.union_left (fn (putOrGet1,putOrGet2) => putOrGet1) 
              (G.find n1, G.find n2))


  fun mkSameLevel(node1, node2) (cone) : cone = 
       (* node1 and node2 must both be either EPS nodes or RHO nodes *)
    case (get_level_and_key' node1, get_level_and_key' node2) of
      (Some(ref l1, _), Some(ref l2, _)) =>          
        if l1=l2 then cone
        else if l1<l2 then lower l1 node2 cone
        else (* l1>l2 *)   lower l2 node1 cone
    | _ => die "mkSameLevel: one of the two nodes was not \
               \and EPS or a RHO node"
  

  (* unifyNodes f (node1, node2) cone : cone
     First lower node1 and node2 to the same level; then union
     the two nodes using union operator f.

     Even though two nodes are combined, the node that has been
     eliminated is not removed from the cone: it can still be found
     under its old key.
  *)

  fun unifyNodes f (node1, node2) cone : cone = 
    let val(node1, node2) = (G.find node1, G.find node2)
    in if G.eq_nodes(node1,node2) then cone
       else
          let val cone1 = mkSameLevel(node1, node2) cone
          in f(node1, node2);
             cone1
          end
    end

  (* unifyRho(rho_node1, rho_node2) cone : cone
     First lower rho_node1 and rho_node2 to the same level; then union
     the two nodes (none of which have children)
  *)

  fun unifyRho(rho_node1, rho_node2) cone : cone = 
    unifyNodes(G.union einfo_combine_rho)(rho_node1, rho_node2) cone

  (* unifyEps(eps_node1, eps_node2) cone : cone
     First lower eps_node1 and eps_node2 to the same level; then union
     the two nodes without duplication of out-edges.
  *)

  fun unifyEps(eps_node1, eps_node2) cone : cone = 
    unifyNodes(G.union_without_edge_duplication (einfo_combine_eps(eps_node1,eps_node2)))
              (eps_node1, eps_node2) cone;


  (* -------------------------------------------------------
   * unify_with_toplevel_rhos_eps(rhos_epss) : unit
   * Unify eps_nodes with toplevel eps node and rho nodes
   * with toplevel rhos of corresponding runtypes. Assume
   * all nodes are of top level. 
   * ------------------------------------------------------- *)

  fun unify_with_toplevel_rhos_eps(rhos_epss) : unit =
    List.apply 
    (fn rho_eps =>
       let fun union_with(toplevel_rho) : unit =
	     if G.eq_nodes(G.find toplevel_rho,G.find rho_eps) then ()
	     else (G.union einfo_combine_rho (G.find toplevel_rho,G.find rho_eps);())
       in if is_arrow_effect rho_eps then
	    if G.eq_nodes(G.find toplevel_arreff,G.find rho_eps) then ()
	    else (G.union_without_edge_duplication 
		  (einfo_combine_eps(toplevel_arreff,rho_eps))
		     (G.find toplevel_arreff,G.find rho_eps);())
	  else if is_rho rho_eps then
	    case get_place_ty rho_eps
	      of Some WORD_RT =>   union_with(toplevel_region_withtype_word)
	       | Some TOP_RT =>    union_with(toplevel_region_withtype_top)
	       | Some BOT_RT =>    union_with(toplevel_region_withtype_bot)
	       | Some STRING_RT => union_with(toplevel_region_withtype_string)
	       | Some REAL_RT =>   union_with(toplevel_region_withtype_real)    
	       | None => die "unify_with_toplevel_rhos.no runtype info"

	  else die "unify_with_toplevel_rhos_eps.not rho or eps"
       end) rhos_epss
    

  (*****************************************************)
  (* generic instance of region- and effect variables  *)
  (*****************************************************)

  (* cone' = instNodes(l) cone:

     l is a list or pairs of effects; it represents a substitution with
     domain map #1 l and range map #2 l. Edges are grafted onto the target
     nodes and level of non-generic nodes that are hence 
     grafted onto the target nodes
     are lowered to be at most the level of their new parent, 
     if their level is higher.
  *)



   val badsubst = "bound_to_free_no_transparent:\
                                 \node with negative level not in domain\
                                 \of substitution"

  fun instNodes l cone = #1(instNodesClever l cone)
  and instNodesClever(l : (effect * effect) list) cone : cone * (effect * delta_phi)list=
    let
      val l = map (fn (dom,rng) => (G.find dom, rng)) l
      (* all first components of l now canonical *)

      (* bound_to_free_no_transparent nodes: map each non-transparent n 
         to itself, if it is not
         in the domain of "subst" and map it to "subst(n)" otherwise; 
         do not included transparent n in the result. Special
         case must be taken to map PUT and GET nodes whose arguments 
         are in the domain in the substitution to correpsonding 
         nodes in the target *)

      (* assumption: no node in "nodes" need be subjected to "find" *)

      fun bound_to_free node=
      let 
          val node = find node
      in
          case G.get_info(node) of
            PUT =>
              (case G.out_of_node node of
                 (rho_origin::_) =>
                       (case !(get_instance rho_origin) of
                          (Some node') => (* generic *) Some(mkPut node')
                        | None => (* non-generic *)
                            Some node
                       )
               | _ => die "instNodes: put node has no region argument"
              )
          | GET =>
              (case G.out_of_node node of
                 (rho_origin::_) =>
                       (case !(get_instance rho_origin) of
                          Some node' => (* generic *) Some(mkGet node')
                        | None => (* non-generic *) Some node
                       )
               | _ => die "instNodes: get node has no region argument"
              )
          | UNION _ => (* node not bound *) 
                       None
          | EPS{instance as ref i,  ...} => 
               ( case i of
                  g as (Some n') => (* generic *) g
                | None => (* non-generic*) Some node
               )
          | RHO{instance as ref i, ...} => die ".bound_to_free"
      end

      fun lower_new_edges(n: effect, new_target_nodes:effect list)cone: cone =
        let val (level, key) = noSome ((get_level_and_key n) , 
                                       "instNodes: no level")
        in List.foldL (lower (!level)) cone new_target_nodes
        end

      val targets_and_new_children: (effect * effect list) list =
                 G.multi_graft bound_to_free l 
    in 
      (List.foldL lower_new_edges cone targets_and_new_children,
       map(fn (target, its_new_children) => (target, Lf(its_new_children)))targets_and_new_children)
    end;

  (*************************************************************************************
   * observe(l: int, source: delta_phi, destination: effect): effect list * delta_phi  *
   *************************************************************************************
   * add all PUT, GET and EPS nodes that can be reached from 'source'                  *
   * as children of 'destination', provided they are not already reachable             *
   * from 'destination' and have level at most 'l' (the level of a PUT or GET          *
   * node is the level of the RHO node it has as its sole child).                      *
   * The nodes thus added are also returned delta_phi, whereas the atomic effects      *
   * that are reachable from source and have level l+1 are accumlated in the           *
   * resulting effect list.                                                            *
   *************************************************************************************)
  
  fun say s = (output(std_out, s); output(!Flags.log, s))

  fun observeDelta(l: int, source: delta_phi, destination: effect): effect list * delta_phi =
    let
      (*val _ = Profile.profileOn()*)
      val destination = G.find destination
(*
      val _ = say("\n-----------------\nLEVEL = " ^ Int.string l ^ "\n")
      val _ = say("SOURCE = ")
      val _ = List.apply (fn source => PP.outputTree(say, layout_effect_deep source, !Flags.colwidth)) sources
      val _ = say("\nDESTINATION = ")
      val _ = PP.outputTree(say, layout_effect_deep destination, !Flags.colwidth)
*)    
      
      (* include_put_or_get(node):  here node is supposed to be 
         PUT or a GET node
         with one child, a RHO node. The return value is true if the RHO node
         has level <= l and false otherwise *)

      val r_acc : effect list ref   = ref []  (* for accumulating nodes of level > l *)

      fun include_put_or_get node : bool =
        case G.out_of_node node of
          [rho] => (case G.find_info(rho) of
                      RHO{level as ref l', ...} => l'<=l
                    | _ => die "include_rho: not RHO node")
        | _ => die "include_rho: not precisely one child of PUT or GET node"

      (* collect: see description below *)


      fun collect(l:int, source: delta_phi)=
      let
        fun sawNode() = ()             (*   *)
        fun sawEdge() = ()             (*   *)
        fun includeUNIONandStop() = () (*    *)
        fun dropUnionAndContinue() = ()  (* *)
        fun sawPutOrGet() = ()           (*  *)
        fun sawEpsDidStop()= ()          (*   *)
        fun sawEpsDidContinue()=()       (*   *)
        fun sawRho() = ()                (*    0 *)

        fun searchDelta(Lf effects, ns:effect list): effect list =
            search'(ns, effects)
          | searchDelta(Br(d1,d2), ns) = 
              searchDelta(d2, searchDelta(d1, ns))

        and search' (b,[]) = b
          | search' (b,x::xs) = 
              (sawEdge();search'(search(x, b), xs))

        and search (n: effect, ns : effect list) : effect list =
          let 
            val _ = sawNode()
            val n = G.find n
            val r = G.get_visited n
          in
            if !r then ns 
            else (r := true;
                  let
                          val i = G.get_info n 
                  in
                          case i of
                            UNION _ =>
                                  (* do not include n itself, but search children *)
                                  (dropUnionAndContinue();
                                   search'(ns,(G.out_of_node n)))
                           | RHO _ => (* do not include it; a PUT or GET will be
                                         included, when necessary *)
                                  (sawRho(); ns)
                           | PUT  => (sawPutOrGet(); if include_put_or_get n then n::ns 
                                                     else (r_acc:= n :: !r_acc; ns))
                           | GET  => (sawPutOrGet(); if include_put_or_get n then n::ns 
                                                     else (r_acc:= n :: !r_acc; ns))
                           | EPS{level as ref l', ...} => 
                                 if l'<=l then
                                   (* include it, without examining children *)
                                   (*(sawEpsDidContinue(); *)
                                    (*List.apply G.visit_all (G.out_of_node n);*)
                                    n::ns
                                 else 
                                  (* do not include n itself, but search children *)
                                  (sawEpsDidContinue(); 
                                   r_acc:= n :: !r_acc;
                                   if false (*!algorithm_R*) then
                                         searchDelta(current_increment n,ns)
                                   else (* S *)
                                         search'(ns, G.out_of_node n))
                  end
                 )
          end
      in
        searchDelta(source,[])
      end
    in
     (*  
     (1) Visit all nodes reachable from 'destination', leaving all
         visited nodes as marked;
     (2) Then traverse nodes reachable from source, collecting those 
         nodes that are not reachable from  'destination' (i.e., are not marked)
         and have level at most 'l'. (This search uses the same mark
         in nodes as (1).)  The result is a list l' of nodes of low level.
         As a side-effect, the atomic effects of level > l (i.e., l+1) are
         collected in the reference r.
     (3) Then unmark all visited nodes from 'source' and 'destination' 
     (4) append l' to the list of children of destination.

      *)

      G.visit_all destination;                        (* (1) *)
      let val nodes_to_add = collect(l,source)       (* (2) *)
      in
        G.unvisit_all destination;                    (* (3) *)
        unvisitDelta source;                          (* (3) *)
        G.add_edges(G.find destination, nodes_to_add);(* (4) *)
        (*Profile.profileOff();*)
(*        say("\nDESTINATION AFTER OBSERVE= ");
        PP.outputTree(say, layout_effect_deep destination, !Flags.colwidth);
        (*input(std_in, 1);*)
*)
        (!r_acc, Lf(nodes_to_add))
      end
    end

  fun observe x = (observeDelta x; ())


    fun eq_effect(node1, node2) = G.eq_nodes(G.find node1,G.find node2)
    fun eq_canonical_effect(node1, node2) = G.eq_nodes(node1,node2)
  (* collapse of cycles in effects: *)
  (* all members of the scc must have the same level; otherwise the graph
     was ill-formed in the first place. Therefore we do not lower levels. *)

  (* findPutAndGets(node) : node list;
     find all the Put and Get nodes reachable from node *)

  fun findPutAndGets(node) = 
      List.all is_put_or_get (G.topsort [node])


  (* sameLists(l1, l2) : bool   returns true if l1 and l2 contain the same elements;
     neither l1 nor l2 contains duplicates; 
     all elements of l1 and l2 are canonical
  *)

  fun sameLists(l1,l2) : bool =
    let fun visit l1 = List.apply (fn node => G.get_visited node := true) l1
        fun unvisit([], acc) = acc
          | unvisit(x::l2',acc) = 
             let val r = G.find_visited x
             in if !r then (r:=false; unvisit(l2',acc))
                else unvisit(l2',false)
             end
        fun unvisited([], acc) = acc
          | unvisited(x::xs, acc) =
             let val r = G.find_visited x
             in if !r then (r:=false; unvisited(xs, false))
                else unvisited(xs, acc)
             end
    in
       visit(l1);       (* (1):mark elements of l1 *)
       unvisit(l2,true) (* (2):check that (1) marked all elements of l2; unmark l2 in the process *)
       andalso unvisited(l1, true) (* (3): check that (2) unmarked all elements of l1; unmark
                                           those that were not unmarked *)
    end


  (* sameEffect(eps1, eps2) cone  returns true iff the same set of PUT and GET nodes
     are reachable from eps1 and eps2 *)

  fun sameEffect(node1, node2) : bool=
        sameLists(findPutAndGets node1, findPutAndGets node2)


  fun einfo_scc_combine(einfo1, einfo2) =  
    case (einfo1,einfo2) of
        (UNION _ , _) => einfo2
      | (_, UNION _) => einfo1
      | (EPS _, EPS _) => einfo1
      | _ => die "einfo_scc_combine: strongly connected\
                 \ component in effect graph contained \
                  \\nnode which was neither an arrow effect nor a union"

  (* arreffs' = contract_effects(arreffs):
     arreffs is a list of nodes, possibly with duplicates.
     arreffs' will not contain duplicates. The nodes in arreffs'
     are the nodes reachable from arreffs, except that strongly
     connnected components of nodes reachable from arreffs have been 
     found and have been collapsed.
  *)

  fun subgraph(l) = G.nodes(G.subgraph(l))

  fun contract_effects (arreffs: effect list): effect list  =
      G.nodes(G.quotient layout_einfo einfo_scc_combine (G.subgraph arreffs));


  fun topsort x = G.topsort x

  fun pix node = case G.get_info(G.find node) of
    RHO{pix, ...} => pix
  | EPS{pix, ...} => pix
  | _ => die "pix: cannot take pre-order index of node which is not a region or effect variable"

  fun get_visited node = G.find_visited node (*G.get_visited(G.find node)*)

  fun get_opt l = List.foldR (fn opt => fn acc => 
                         case opt of Some t => t::acc | None => acc) [] l

  fun layoutEtas(etas: effect list): StringTree list = 
       get_opt(map (fn eff => if is_rho eff then 
                                     if !Flags.print_regions 
                                     then Some(layout_effect_deep eff)
                                     else None
                              else if !Flags.print_effects
                                   then Some(layout_effect_deep eff)
                                   else None) (etas))

  val reset_cone = Cone.reset
  fun reset() = (reset_cone emptyCone;
		 resetCount();
                 globalIncs:= Increments.empty)

  fun commit() = commit_count()

  (**************************************)
  (*  for multiplicity inference:       *)
  (**************************************)

  fun key_of_get_or_put node = case G.out_of_node node of
      [rho_node] => key_of_rho rho_node
      | _ => die "key_of_get_or_put"

  fun rho_of node = case G.out_of_node node of [rho_node] => rho_node | _ => die "rho_of"
        
      

  exception AE_LT


  fun ae_lt(node1, node2) = (* GET > PUT > EPS *)
    let val node1 = G.find node1
        val node2 = G.find node2
    in case (G.get_info(node1), G.get_info(node2)) of
        (EPS _, EPS _) => get_key_of_eps node1 < get_key_of_eps node2
      | (EPS _, _) => true
      | (PUT, PUT) => key_of_get_or_put node1 < key_of_get_or_put node2
      | (PUT, EPS _) => false
      | _ => raise AE_LT
    end

  local (* sorting of atomic effects *)
    fun merge([], ys) = ys:effect list
      | merge(xs, []) = xs
      | merge(l as x::xs, r as y:: ys) =
             if ae_lt(x, y) then x::merge(xs, r)
             else y:: merge(l, ys)
  
    (* sort: top-down mergesort*)
  
    fun sort [] = []
      | sort [x] = [x]
      | sort xs =
        let val k = length xs div 2
        in merge(sort(take(k, xs)),
                 sort(drop(k, xs)))
        end

  in 
     val sort_ae = sort

  end
  (* mk_phi(eps_node): returns list of atomic effects in the effect which has
     eps_node as its primary effect variable. *)

  fun mk_phi eps_node =
     let val n = G.find eps_node
     in case G.get_info n of
          EPS{represents = Some l, ...} => l
        | UNION{represents = Some l} => l
        | PUT  => [n]
        | GET  => []
        | RHO _ => []
        | _ => die "mk_phi"
     end

  fun visit_eps_or_rho node acc = 
    let val n = G.find node
        val i = G.get_info n
        val r = G.get_visited n
    in 
        case i of 
          EPS _ => (r:=true; r::acc)
        | RHO{put, ...} =>
           (case put of 
              None => (r:=true; r::acc)
            | Some n => 
                   let
                       val r' = G.get_visited(n)
                   in r:= true; r':=true; r::r'::acc 
                   end)
        | _ => die "visit_eps_or_rho: neither eps nor rho node"
    end

  fun removeatomiceffects(psi, []) = psi
    | removeatomiceffects(psi: (effect * 'a) list, discharged_basis: effect list): (effect*'a) list =
      (* each member of discharged_basis is either a region variable or an arrow effect;
         now remove from psi all ae:m for which ae takes the form eps in discharged_basis
         or PUT rho or GET rho for rho in discharged_basis:
      *)
      let val refs = List.foldL visit_eps_or_rho [] discharged_basis 
          fun keep (ae,mul): bool = not(!(G.get_visited(G.find ae)))
      in 
         List.all keep psi footnote
            List.apply (fn r => r := false) refs
      end

  (************************************)
  (* after region inference: compute  *)
  (* the sets of atomic effects that arrow effect *)
  (* handles represent. Only arrow effects*)
  (* and PUT effects are included      *)
  (*************************************)

  structure MultiMerge =
    struct
      (* A multi-way merge can be implemented by keeping a heep
         of list of elements to be sorted. The lists in the heap
         are non-empty. The key value of a list is the key value
         of the first element of the list.*)
    
      fun leq_key(i, j) = ae_lt(i,j) orelse eq_effect(i,j)
    
      structure HI = struct
        type elem =  effect list
        fun leq(x::_, y::_) = leq_key(x,y)
          | leq _ = die "leq"
        fun layout(_)=  die "layout"
      end
    
      structure Heap = Heap(structure HeapInfo = HI)
    
      fun merge(ae1, ae2) = ae1
      fun eq(ae1, ae2) = eq_effect(ae1, ae2)
    
      fun makeHeap ll =
        let fun mkHeap([], h) = h
              | mkHeap([]::rest, h) = mkHeap(rest,h)
              | mkHeap( l::rest, h) = mkHeap(rest, Heap.insert l h)
        in
            mkHeap(ll, Heap.empty)
        end
    
      fun insert([], h) = h
        | insert( l, h) = Heap.insert l h
    
      fun merge_against(min, h) =
          if Heap.is_empty h then [min]
          else case Heap.delete_min h
		 of (l1 as (x1::xs1), h1) =>
		   if eq(min,x1) then 
		     if Heap.is_empty h1 then merge(min,x1)::xs1
		     else merge_against(merge(min,x1), insert(xs1, h1))
                   else 
		     if Heap.is_empty h1 then min :: l1
		     else min :: merge_against(x1, insert(xs1, h1))
		  | _ => die "merge_against" 
    
       fun merge_all h =
          if Heap.is_empty h then []
          else case Heap.delete_min h
		 of (x1::xs1, h1) => merge_against(x1, insert(xs1,h1))
		  | _ => die "merge_all" 
    
      fun multimerge (ll: HI.elem list) =
          merge_all(makeHeap ll)
    end


  fun insert_into_list(eps,[]) = [eps]
    | insert_into_list(eps, l as eps'::rest) =
        if ae_lt(eps,eps') then eps ::l
        else if eq_effect(eps,eps') then l
        else eps' :: insert_into_list(eps, rest)

  fun check_represents(l) =  (* check that all members of l are atomic effects*)
    (map (fn n => case G.get_info n of
             EPS _ => ()
           | PUT  => ()
           | GET  => () 
           | _ => (log_string "check_represents failed on effect:";
                   log_tree(layout_effect_deep n);
                   die "check_represents")) l;
     l)
    

  fun bottom_up_eval (g : effect list) : unit =
      (* 
       * bottom_up_eval f g : evaluates the graph g bottom up using function f.
       * f is supposed to be applied to the info of a node n and the info of all 
       * the nodes in its out-set after bottom_up_eval of these nodes.
       * The graph is suppossed to acyclic.
       *)
      let
        fun search (n: effect) : effect list  = 
          let 
            val n = find n
            val r = G.get_visited n
          in
            if !r then
              case G.get_info n of 
                EPS{represents = Some l, ...} => insert_into_list(n,l)
              | UNION{represents = Some l} => l
              | PUT => [n]
              | GET => []
              | _ => die "bottom_up_eval: unexpected node(1)"
            else
              (r:= true;
               case G.get_info n of
                 EPS{represents, key,level,pix,instance} =>
                   (let 
                      val ns = G.out_of_node n
                      val result = MultiMerge.multimerge(map search ns)
                    in
                      G.set_info n (EPS{represents= Some ((*check_represents*) result), key=key,level=level,pix =pix,instance=instance});
                      insert_into_list(n,result)
                    end)            
               | UNION{represents} =>
                   (let 
                      val ns = G.out_of_node n
                      val result = MultiMerge.multimerge(map search ns)
                    in
                      G.set_info n (UNION{represents= Some ((*check_represents*) result)});
                      result
                    end)            
               | PUT => [n]
               | GET => []
               | RHO _ => []
              )
          end
      in
        map search g;(* Each node may potentially begin a new tree, so 
                             * we have to evaluate for each node. Note however,
                             * that the graph in total is only traversed once, 
                             * (ensured by the use of the mark visited)
                             *)
        G.unvisit g
      end


   (* eval_phis(phis): all members of phis must be EPS nodes; 
      we now first contract all cycles, then
      do a bottom-up evaluation of the graph *)

  fun eval_phis (phis: effect list) : unit =
      (G.remove_cycles(G.subgraph phis);
       bottom_up_eval(G.nodes(G.subgraph phis)))

  fun represents(eps) =
    case G.get_info(G.find eps) of
      EPS{represents = Some l, ...} => l
    | _ => die "represents"

end; 

(*$TestEffect: 
        Effect DiGraph Flags BasicIO Crash Report PrettyPrint Stack UnionFindPoly 
*)
structure BasicIO = BasicIO();
structure Crash = Crash(structure BasicIO = BasicIO);
structure Flags = Flags(structure Crash = Crash);
structure Report = Report(structure BasicIO = BasicIO);
structure PP = PrettyPrint(structure Report = Report
                           structure Crash = Crash
                           structure Flags = Flags);
structure UF = UF_with_path_halving_and_union_by_rank();
structure Stack = Stack();
structure DiGraph = DiGraph(structure UF = UF
                            structure Stack = Stack
                            structure PP = PP
                            structure Flags = Flags
                            structure Crash = Crash)
structure Effect = Effect(structure G = DiGraph
                          structure PP = PP
                          structure Crash = Crash
                          structure Report = Report);
open Effect;

fun pp(t) = PP.flatten1 t
fun say s = output(std_out, s^"\n")
fun etest(label,expected,found) =
 say(label ^ (if expected = found then " OK" else " ****** NOT OK *******" ^
"\n expected: " ^ expected ^ 
"\n found:    " ^ found));
              
fun etest'(label,expected,found) = say found;



val rho1 = mkRho(5,1)
val rho2 = mkRho(6,2)
val e = mkUnion[mkPut rho1, mkPut rho2]
val s1 = pp(layout_effect_deep e);
val _ = DiGraph.union einfo_combine (rho1, rho2)
val s2 = pp(layout_effect_deep e);


say "---------------testing cones ---------------------";

val _ = resetCount();
val ec = emptyCone;
say "the empty cone:";
say(pp (layoutCone ec));
say "now creating two region variables at level 0";
val c0 = push ec;
val (rho1,c1) = freshRho(c0)
val (rho2,c2) = freshRho(c1);
say "now the cone is:";
say(pp (layoutCone c2));
say "now pushing new level and creating two effect variables";
val c2' = push c2
val (eps3,c3) = freshEps(c2')
val (eps4,c4) = freshEps(c3);
say "now the cone is: ";
say(pp (layoutCone c4));
say "now lowering e4 to level 1: ";
val c5 = lower 1 eps4 c4;
say(pp (layoutCone c5));
say "now creating rho6: ";
val (rho6,c6) = freshRho c5;
say(pp (layoutCone c6));
say "now making Put(r6)";
val put_r6 = mkPut rho6;
say "now inserting edge from eps3 to put(r6): ";
val _ = DiGraph.mk_edge(eps3, put_r6);
say(pp (layoutCone c6));
say "now lowering eps3 to level 1, r6 should follow suit ";
val c7 = lower 1 eps3 c6;
say(pp (layoutCone c7));
val _ = etest("checkpoint 1: ", 
              "{level 1={1=r1,2=r2,3=e3(put(r5)),4=e4,5=r5},level 2={}}",
              pp(layoutCone c7));          
say "now popping layer";
val (layer1, c8) = pop c7;
say "top layer was";
say(pp(layoutLayer layer1));
say "remaing cone is";
say(pp(layoutCone c8));

say "---------------testing unification of region variables ---------------------";

val _ = resetCount();
val ec = emptyCone;
val c0 = push ec;
val (rho1,c1) = freshRho(c0)
val (rho2,c2) = freshRho(c1);
say "now the cone is:";
etest("unifyRho1", "{level 1={1=r1,2=r2}}", (pp (layoutCone c2)));
say "making put rho1 and put rho2: ";
val (p1,p2) = (mkPut rho1, mkPut rho2);
say "now the cone is:";
etest("unifyRho2", "{level 1={1=r1,2=r2}}", pp (layoutCone c2));
say "unifying rho1 and rho2";
val c3 = unifyRho(rho1,rho2) c2;
say "now the cone is:";
say(pp (layoutCone c3));
say "are rho1 and rho2 now equal (after find)?";
val equal = DiGraph.eq_nodes(DiGraph.find rho1, DiGraph.find rho2);
etest("unifyRho3", "true", Bool.string equal);

say "put rho1 has become:";
etest("unifyRho4", "put(r1)", pp(layout_effect_deep (DiGraph.find p1)));
say "put rho2 has become:";
val _ = say(pp(layout_effect_deep (DiGraph.find p2)));

say "---------------testing unification of arrow effects ---------------------";

fun mkRhos 0 (cone,acc) =acc
  | mkRhos n (cone, acc) = 
       let val (rho, c') = freshRho(cone)
       in mkRhos(n-1)(c',rho::acc)
       end
fun mkEpss 0 (cone,acc) =acc
  | mkEpss n (cone, acc) = 
       let val (rho, c') = freshEps(cone)
       in mkEpss(n-1)(c',rho::acc)
       end;
(* case 1 *)
val _ = resetCount();
val ec = emptyCone;
val c = push ec;
val (eps1,c) = freshEps(c)
val (rho1,c) = freshRho(c)
val _ = edge(eps1,mkPut rho1)
val c = push c
val (eps2,c) = freshEps(c)
val (rho2,c) = freshRho(c)
val _ = edge(eps2,mkPut rho2);
val _ = say "Case 1, before unification of eps1 and eps2: cone is";
val _ = say (pp(layoutCone c));
val c= unifyEps(eps1,eps2)c;
val _ = say "Case 1, after unification of eps1 and eps2: cone is";
val _ = etest("Case 1", "{level 1={1=e1(put(r2),put(r4)),2=r2,3=e1(put(r2),put(r4)),4=r4},level 2={}}",(pp(layoutCone c)));

(* case 2 *)

val _ = resetCount();
val ec = emptyCone;
val c = push ec;
val (eps1,c) = freshEps(c)
val (rho2,c) = freshRho(c)
val p2 = mkPut rho2
val _ = edge(eps1,p2)
val c = push c
val (eps3,c) = freshEps(c)
val _ = edge(eps3,p2);
val _ = say "Case 2, before unification of eps1 and eps3: cone is";
val _ = say (pp(layoutCone c));
val c= unifyEps(eps1,eps3)c;
val _ = say "Case 2, after unification of eps1 and eps3: cone is";
val _ = etest("Case 2", "{level 1={1=e1(put(r2)),2=r2,3=e1(put(r2))},level 2={}}", (pp(layoutCone c)));

(* case 3 *)

val _ = resetCount();
val ec = emptyCone;
val c = push ec;
val (eps1,c) = freshEps(c)
val (rho2,c) = freshRho(c)
val g2 = mkGet rho2
val _ = edge(eps1,g2)
val c = push c
val (eps3,c) = freshEps(c)
val (rho4,c) = freshRho(c)
val _ = edge(eps3,mkPut rho4);
val _ = edge(eps3,eps1);
val _ = say "Case 3, before unification of eps1 and eps3: cone is";
val _ = say (pp(layoutCone c));
val c= unifyEps(eps1,eps3)c;
val _ = say "Case 3, after unification of eps1 and eps3: cone is";
val _ = etest("Case 3" ,
"{level 1={1=e1(get(r2),@e1,put(r4)),2=r2,3=e1(get(r2),@e1,put(r4)),4=r4},level 2={}}",(pp(layoutCone c)));

(* case 4 *)

val _ = resetCount();
val ec = emptyCone;
val c = push ec;
val (eps1,c) = freshEps(c)
val (eps2,c) = freshEps(c)
val (eps3,c) = freshEps(c)
val (rho4,c) = freshRho(c)
val _ = edge(eps1,eps2);
val _ = edge(eps2, eps3);
val _ = edge(eps3, eps1);
val _ = edge(eps3, mkGet(rho4));
val c = push c
val (eps5,c) = freshEps(c)
val (eps6,c) = freshEps c;
val (rho7,c) = freshRho c;
val _ = edge(eps5,eps6)
val _ = edge(eps6,eps5)
val _ = edge(eps5,mkPut(rho7));
val _ = say "Case 4, before unification of eps6 and eps1: cone is";
val _ = say (pp(layoutCone c));
val c= unifyEps(eps6,eps1)c;
val _ = say "Case 4, after unification of eps6 and eps1: cone is";
val _ = etest("Case 4" ,
"{level 1={1=e6(e5(put(r7),@e6),e2(e3(get(r4),@e6))),\
\2=e2(e3(get(r4),e6(e5(put(r7),@e6),@e2))),\
\3=e3(get(r4),e6(e5(put(r7),@e6),e2(@e3))),\
\4=r4,5=e5(put(r7),e6(@e5,e2(e3(get(r4),@e6)))),\
\6=e6(e5(put(r7),@e6),e2(e3(get(r4),@e6))),7=r7},level 2={}}",(pp(layoutCone c)));

say "-------------- end of test of unification ------------";


fun loop 0 (cone, l) = (cone, l)
  | loop n (cone, l) = 
      let val (rho, cone') = freshRho cone
      in loop (n-1)(cone', rho::l)
      end;

val _ = say "now building list of 50000 region variables"
val (big_cone, big_list) = loop 50000 (push ec, []);

val _ = say "ready to unify the 5000 region variables";

fun unified() = List.foldL (fn rho1 => fn (cone,rho) => (unifyRho(rho1,rho)cone,rho1))
                         (big_cone,(hd big_list))
                         big_list;



val _ = say " ---------------- test of instNodes ---------------";
val _ = resetCount();
val c = emptyCone;
val c = push c;
     (* domain of subst: eps2,eps3,rho4 *)
val (rho1,c) = freshRho c
val (eps2,c) = freshEps c
val (eps3,c) = freshEps c
val (rho4,c) = freshRho c
val u = mkUnion [mkPut rho1, eps3];
val _ = edge(eps2, u);
val _ = edge(eps3, mkGet rho4);
    (* range of subst: eps5, eps6, rho7 *)
val (eps5,c) = freshEps c
val (eps6,c) = freshEps c
val (rho7,c) = freshRho c
val _ = edge(eps5,eps6)
val _ = edge(eps5, mkPut rho7)
    (* the substitution (bottom-up listing) *)
val subst = [(rho4,rho7), (eps3,eps6), (eps2,eps5)];
val _ = say "before generic instantiation the cone is: "
val _ = say (pp(layoutCone c));
(*val lp = (DiGraph.multi_graft transparent subst);*)
val c = instNodes subst c;
val _ = say "after generic instantiation the cone is: "
val _ = etest("instNodes, case1", 
"{level 1={1=r1,2=e2(U(e3(get(r4)),put(r1))),3=e3(get(r4)),4=r4,5=e5(put(r1),put(r7),e6(get(@r7))),6=e6(get(r7)),7=r7}}",
(pp(layoutCone c)));

val _ = say " ---------------- test of observe ---------------";
fun show_node n = pp(layout_effect_deep(DiGraph.find n))

(* case 1 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (rho2,c) = freshRho c;
val (rho3,c) = freshRho c;
val (rho4,c) = freshRho c;
val (rho5,c) = freshRho c;
val putRho1 = mkPut rho1;
val putRho2 = mkPut rho2;
val putRho4 = mkPut rho4;
val getRho5 = mkGet rho5;
val destination = mkUnion[putRho2, getRho5]
val _ = edge(eps1, putRho2);
val _ = edge(eps1, mkGet rho3);
val c= push c;
val (rho6,c) = freshRho c;
val (eps7,c) = freshEps c
val _ = edge(eps7, putRho4);
val source = mkUnion[eps1,eps7,mkUnion[mkGet rho6, mkPut rho5]];
val _ = say "source before observe(1,source,destination):";
val _ = say (show_node source)
val _ = say "destination before observe(1,source,destination):";
val _ = say (show_node destination)
val destination' = observe(1,[source], destination);
val _ = say "source after observe(1,source,destination):";
val _ = say (show_node source)
val _ = say "result of observe(1,source,destination):";
val _ = etest("observe, Case 1", 
"U(e1(get(r3),put(r2)),put(r4),put(r5),get(@r5),@put)",
(show_node destination'));

(* case 2 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (rho2,c) = freshRho c;
val (rho3,c) = freshRho c;
val (rho4,c) = freshRho c;
val (rho5,c) = freshRho c;
val putRho1 = mkPut rho1;
val putRho2 = mkPut rho2;
val putRho4 = mkPut rho4;
val getRho5 = mkGet rho5;
val destination = mkUnion[getRho5]
val _ = edge(eps1, putRho2);
val _ = edge(eps1, mkGet rho3);
val c= push c;
val (rho6,c) = freshRho c;
val (eps7,c) = freshEps c
val _ = edge(eps7, putRho4);
val source = mkUnion[eps1,eps7,mkUnion[mkGet rho6, mkPut rho5]];
val _ = say "source before observe(1,source,destination):";
val _ = say (show_node source)
val _ = say "destination before observe(1,source,destination):";
val _ = say (show_node destination)
val destination' = observe(1,[putRho2,source], destination);
val _ = say "source after observe(1,source,destination):";
val _ = say (show_node source)
val _ = say "result of observe(1,source,destination):";
val _ = etest("observe, Case 2", 
"U(e1(get(r3),put(r2)),put(r4),put(r5),get(@r5))",
(show_node destination'));

val _ = say " ---------------- test of sameSetUptoBijection  ---------------";

(* case 1*)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (eps2,c) = freshEps c;
val (rho3,c) = freshRho c;
val (rho4,c) = freshRho c;
val _ = edge(eps1,mkPut rho3)
val _ = edge(eps2,mkPut rho4)
val case1 = sameSetUptoBijection  [(eps1,eps2),(rho3,rho4)](eps1,eps2);
val _ = etest("sameSetUptoBijection, case 1", "true", Bool.string case1);

(* case 2 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (eps2,c) = freshEps c;
val (rho3,c) = freshRho c;
val (rho4,c) = freshRho c;
val _ = edge(eps1,mkPut rho3)
val _ = edge(eps2,mkPut rho4)
val case2 = sameSetUptoBijection  [(eps1,eps2)](eps1,eps2);
val _ = etest("sameSetUptoBijection, case 2", "false", Bool.string case2);

(* case 3 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (eps2,c) = freshEps c;
val (rho3,c) = freshRho c;
val (rho4,c) = freshRho c;
val _ = edge(eps1,mkPut rho3)
val _ = edge(eps2,mkPut rho4)
val case3 = sameSetUptoBijection  [(rho3,rho4)](eps1,eps2);
val _ = etest("sameSetUptoBijection, case 3", "false", Bool.string case3);

(* case 4 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (eps2,c) = freshEps c;
val (rho3,c) = freshRho c;
val p = mkPut rho3
val _ = edge(eps1,p)
val _ = edge(eps2,p)
val case4 = sameSetUptoBijection  [(eps1,eps2)](eps1,eps2);
val _ = etest("sameSetUptoBijection, case 4", "true", Bool.string case4);

(* case 5 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (eps2,c) = freshEps c;
val (rho3,c) = freshRho c;
val p = mkPut rho3
val _ = edge(eps1,p)
val _ = edge(eps2,p)
val _ = edge(eps2, mkGet rho3)
val case5 = sameSetUptoBijection  [(eps1,eps2)](eps1,eps2);
val _ = etest("sameSetUptoBijection, case 5", "false", Bool.string case5);

(* case 6 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (rho2,c) = freshRho c;
val (rho3,c) = freshRho c;
val (eps4,c) = freshEps c;
val p = mkPut rho3
val _ = edge(eps1,mkPut rho2)
val _ = edge(eps1,p)
val _ = edge(eps4, p)
val case6 = sameSetUptoBijection  [(eps1,eps4)](eps1,eps4);
val _ = etest("sameSetUptoBijection, case 6", "false", Bool.string case6);

(* case 7 *)

val _ = resetCount();
val c = emptyCone;
val c = push c;
val (eps1,c) = freshEps c;
val (eps2,c) = freshEps c;
val (rho3,c) = freshRho c;
val (eps4,c) = freshEps c;
val (eps5,c) = freshEps c;
val p = mkPut rho3
val _ = edge(eps1,eps5)
val _ = edge(eps1,p)
val _ = edge(eps2, p)
val _ = edge(eps2, eps4)
val case7 = sameSetUptoBijection  [(eps1,eps4),(eps5,eps2)](eps1,eps2);
val _ = etest("sameSetUptoBijection, case 7", "false", Bool.string case7);

