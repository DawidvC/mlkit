(* This file is auto-generated with Tools/GenOpcodes on *)
(* Mon Oct 30 17:09:55 2000 *)
signature BUILT_IN_C_FUNCTIONS_KAM = 
  sig
    val name_to_built_in_C_function_index : string -> int
  end

functor BuiltInCFunctionsKAM () : BUILT_IN_C_FUNCTIONS_KAM = 
  struct
    fun name_to_built_in_C_function_index name =
      case name
        of "stdErrStream" => 0
      | "stdOutStream" => 1
      | "stdInStream" => 2
      | "sqrtFloat" => 3
      | "lnFloat" => 4
      | "negInfFloat" => 5
      | "posInfFloat" => 6
      | "sml_getrutime" => 7
      | "sml_getrealtime" => 8
      | "sml_localoffset" => 9
      | "exnName" => 10
      | "printString" => 11
      | "printNum" => 12
      | "implodeChars" => 13
      | "implodeString" => 14
      | "concatString" => 15
      | "sizeString" => 16
      | "subString" => 17
      | "div_int_" => 18
      | "mod_int_" => 19
      | "word_sub0" => 20
      | "word_update0" => 21
      | "word_table0" => 22
      | "table_size" => 23
      | "allocString" => 24
      | "updateString" => 25
      | "chrChar" => 26
      | "greaterString" => 27
      | "lessString" => 28
      | "lesseqString" => 29
      | "greatereqString" => 30
      | "equalString" => 31
      | "div_word_" => 32
      | "mod_word_" => 33
      | "quotInt" => 34
      | "remInt" => 35
      | "divFloat" => 36
      | "sinFloat" => 37
      | "cosFloat" => 38
      | "atanFloat" => 39
      | "asinFloat" => 40
      | "acosFloat" => 41
      | "atan2Float" => 42
      | "expFloat" => 43
      | "powFloat" => 44
      | "sinhFloat" => 45
      | "coshFloat" => 46
      | "tanhFloat" => 47
      | "floorFloat" => 48
      | "ceilFloat" => 49
      | "truncFloat" => 50
      | "stringOfFloat" => 51
      | "isnanFloat" => 52
      | "realInt" => 53
      | "generalStringOfFloat" => 54
      | "closeStream" => 55
      | "openInStream" => 56
      | "openOutStream" => 57
      | "openAppendStream" => 58
      | "flushStream" => 59
      | "outputStream" => 60
      | "inputStream" => 61
      | "lookaheadStream" => 62
      | "openInBinStream" => 63
      | "openOutBinStream" => 64
      | "openAppendBinStream" => 65
      | "sml_errormsg" => 66
      | "sml_errno" => 67
      | "sml_access" => 68
      | "sml_getdir" => 69
      | "sml_isdir" => 70
      | "sml_mkdir" => 71
      | "sml_chdir" => 72
      | "sml_readlink" => 73
      | "sml_islink" => 74
      | "sml_realpath" => 75
      | "sml_devinode" => 76
      | "sml_rmdir" => 77
      | "sml_tmpnam" => 78
      | "sml_modtime" => 79
      | "sml_filesize" => 80
      | "sml_remove" => 81
      | "sml_rename" => 82
      | "sml_settime" => 83
      | "sml_opendir" => 84
      | "sml_readdir" => 85
      | "sml_rewinddir" => 86
      | "sml_closedir" => 87
      | "sml_system" => 88
      | "sml_getenv" => 89
      | "terminate" => 90
      | "sml_commandline_name" => 91
      | "sml_commandline_args" => 92
      | "sml_localtime" => 93
      | "sml_gmtime" => 94
      | "sml_mktime" => 95
      | "sml_asctime" => 96
      | "sml_strftime" => 97
      | _ => ~1
  end
