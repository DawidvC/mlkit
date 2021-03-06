#include "stdlib.h"
#include "stdio.h"
#include "string.h"
#include "sql.h"
#include "sqlext.h"
#include "../../Runtime/List.h"
#include "../../Runtime/String.h"
#include "DbCommon.h"

#define MAXMSG 1024

enum DBReturn
{
  DBError = 0, 
  DBData = 1, 
  DBDml = 2,
  DBEod = 3
};

enum COMMIT_MODE
{
  AUTO_COMMIT,
  MANUAL_COMMIT
};

struct myString
{
  unsigned char *cstring;
  unsigned int length;
};

struct freeDBC
{
  SQLHDBC dbc;
  struct freeDBC *next;
};

struct bugs
{
  int QfreeDBCs;
  struct freeDBC *freeDBC;
};

typedef struct 
{
  SQLHENV envhp;
  int dbid;
  char msg[MAXMSG];
  void *freeSessionsGlobal;
  unsigned int number_of_sessions;
  unsigned char about_to_shutdown; // != 0 if we are shutting this environment down
  struct myString DSN;
  struct myString UID;
  struct myString PW;
  struct bugs bugs;
} oDb_t;

typedef struct oSes
{
  struct oSes *next;
  SQLHDBC connhp;
  SQLHSTMT stmthp;
  SQLSMALLINT cols;
  int needsClosing;
  oDb_t *db;
  enum COMMIT_MODE mode;
  int *datasizes;
  char *rowp;
  int rowpSize;
  char msg[MAXMSG];
} oSes_t;

typedef struct
{
  char *DSN;
  char *username;
  char *password;
  thread_lock tlock;
  cond_var cvar;
  int maxdepth;
  oDb_t *dbspec;
} db_conf;

typedef struct
{
  void *dbSessions;
  void *freeSessions;
  int theOne;
  int depth;
} dbOraData;


#ifdef MAX
#undef MAX
#endif
#define MAX(a,b) ((a) < (b) ? (b) : (a))

#define ErrorCheck(status,handletype,handle,buffer,code,rd) {                        \
  if (status != SQL_SUCCESS)                                                         \
  {                                                                                  \
    if (putmsg(status, handletype, handle, buffer, MAXMSG, rd)!=SQL_SUCCESS)         \
    {                                                                                \
      code                                                                           \
    }                                                                                \
  }                                                                                  \
}

static SQLRETURN
putmsg(SQLRETURN status, SQLSMALLINT handletype, SQLHANDLE handle, char *msg, int msgLength, void *ctx)/*{{{*/
{
  int i;
  SQLCHAR SQLstate_ptr[] = "123456"; // space for 5 characters in code
  SQLINTEGER naterrptr;
  SQLSMALLINT msgl;
  SQLRETURN stat;
  switch (status)
  {
    case SQL_SUCCESS:
      msg[0] = 0;
      return SQL_SUCCESS;
      break;
    case SQL_SUCCESS_WITH_INFO:
      // dblog1(ctx,"putmsg->withInfo");
      i = 0;
      do
      {
        if (i != 0)
        {
          if (msgl < msgLength)
          {
            msg[msgl] = 0;
            dblog1(ctx, (char *) msg);
          }
          else
          {
            dblog1(ctx,"ErrorBuffer too small");
          }
        }
        i++;
        status = SQLGetDiagRec(handletype, handle, (SQLSMALLINT) i, SQLstate_ptr, &naterrptr, (SQLCHAR *) msg,
                               msgLength - 1, &msgl);
	// dblog2(ctx,"status = ", status);
	// dblog1(ctx,"SQLstate = ");
	// dblog1(ctx,SQLstate_ptr);
      }
      while (status == SQL_SUCCESS || status == SQL_SUCCESS_WITH_INFO);
      return SQL_SUCCESS;
      break;
    default:
      // dblog1(ctx,"putmsg->error");
      stat = status;
      i = 0;
      do
      {
        if (i != 0)
        {
          if (msgl < msgLength)
          {
            msg[msgl] = 0;
            dblog1(ctx, msg);
          }
          else
          {
            dblog1(ctx,"ErrorBuffer too small");
          }
        }
        i++;
        status = SQLGetDiagRec(handletype, handle, i, SQLstate_ptr, &naterrptr, (SQLCHAR *) msg, 
                               msgLength - 1, &msgl);
	// dblog2(ctx,"status = ", status);
	// dblog2(ctx,"msgl = ", msgl);
	// dblog1(ctx,"msg = ");
	// dblog1(ctx,msg);
	// dblog1(ctx,"SQLstate = ");
	// dblog1(ctx,SQLstate_ptr);
      }
      while (status == SQL_SUCCESS || status == SQL_SUCCESS_WITH_INFO);
      // dblog1(ctx,"putmsg->error.end");
      return stat;
      break;
  }
  return SQL_ERROR;
}/*}}}*/

static oDb_t * 
DBinitConn (void *ctx, SQLCHAR *DSN, SQLCHAR *userid, SQLCHAR *password, int dbid)/*{{{*/
{
  SQLRETURN status;
  oDb_t *db;
  unsigned char *ctmp;
  unsigned int dbsize = strlen((char *) DSN) + strlen((char *) userid) + strlen((char *) password) + 3;
  db = (oDb_t *) malloc(sizeof(oDb_t) + dbsize);
  if (!db) 
  {
    dblog1(ctx, "Malloc failed");
    return NULL;
  }
  ctmp = (unsigned char *) db;
  ctmp += sizeof(oDb_t);
  db->DSN.cstring = ctmp;
  db->DSN.length = strlen((char *) DSN);
  ctmp += db->DSN.length + 1;
  db->UID.cstring = ctmp;
  db->UID.length = strlen((char *) userid);
  ctmp += db->UID.length + 1;
  db->PW.cstring = ctmp;
  db->PW.length = strlen ((char *) password);
  strcpy((char *) db->DSN.cstring, (char *) DSN);
  strcpy((char *) db->UID.cstring, (char *) userid);
  strcpy((char *) db->PW.cstring, (char *) password);

  db->dbid = dbid;
  db->freeSessionsGlobal = NULL;
  db->envhp = NULL;
  db->number_of_sessions = 0;
  db->about_to_shutdown = 0;
  db->bugs.QfreeDBCs = 0;
  db->bugs.freeDBC = NULL;
  db->msg[0] = 0;
  status = SQLSetEnvAttr(SQL_NULL_HANDLE, SQL_ATTR_CONNECTION_POOLING, (SQLPOINTER) SQL_CP_ONE_PER_HENV, 0);
  ErrorCheck(status, SQL_HANDLE_ENV, SQL_NULL_HANDLE, db->msg,
      dblog1(ctx, "Connection pooling setup failed");
      return NULL;,
      (SQLCHAR *) ctx
      )
  status = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &db->envhp);
  ErrorCheck(status, SQL_HANDLE_ENV, db->envhp, db->msg,
      dblog1(ctx, "SQLAllocHandle failed");
      return NULL;,
      ctx
      )

  status = SQLSetEnvAttr(db->envhp, SQL_ATTR_ODBC_VERSION, (SQLPOINTER) SQL_OV_ODBC3, 0);
  ErrorCheck(status, SQL_HANDLE_ENV, db->envhp, db->msg,
      dblog1(ctx, "ODBC version setup failed");
      return NULL;,
      ctx
      )
  return db;
}/*}}}*/

#define ERRORCODETOINT(buf)(buf[0] * 256 + buf[1])

static void
DBCheckNSetIfServerGoneBad(oDb_t *db, SQLSMALLINT ht, SQLHANDLE h, void *ctx, int lock)/*{{{*/
{
  db_conf *dbc;
  SQLSMALLINT rvlength;
  char buf[9];
  SQLGetDiagField(ht, h, 1, SQL_DIAG_SQLSTATE, buf, 9, &rvlength);
  if (rvlength < 2) return;
  switch (ERRORCODETOINT(buf))
  {
    case 12343: // SQLERROR 07xxx  :  bug
      dblog1(ctx, "Database driver error. This indicates a bug in odbc.c");
      break;
    case 12344: // SQLERROR 08xxx  :  Bad Connection
      dblog1(ctx, "Database connection gone bad. ODBC environment about to shutdown");
      break;
    case 18765: // SQLERROR IMxxx  :  Bad configuration
      dblog1(ctx, "Database configuration gone bad. ODBC environment about to shutdown");
      break;
    default:
      return;
  }
  dbc = (db_conf *) apsmlGetDBData(db->dbid,ctx);
  if (!dbc) return;
  if (lock) lock_thread(dbc->tlock);
  if (db == dbc->dbspec) dbc->dbspec = NULL;
  db->about_to_shutdown = 1;
  if (lock) unlock_thread(dbc->tlock);
  return;
}/*}}}*/

static void 
DBShutDown(oDb_t *db, void *ctx)/*{{{*/
{
  SQLRETURN status;
  if (!db) return;
  status = SQLFreeHandle(SQL_HANDLE_ENV, db->envhp);
  ErrorCheck(status, SQL_HANDLE_ENV, db->envhp, db->msg,
      dblog1(ctx, "Closing down the session pool gave an error, we are loosing our reference to this memory");
      free(db);,
      ctx
      )
  free(db);
  return;
}/*}}}*/

static void
DBShutDownWconf(void *db2, void *ctx)/*{{{*/
{
  oDb_t *db;
  db_conf *db1 = (db_conf *) db2;
  if (!db1 || !(db1->dbspec)) return;
  db = db1->dbspec;
  db1->dbspec = NULL;
  DBShutDown(db, ctx);
  return;
}/*}}}*/

static oSes_t *
DBgetSession (oDb_t *db, void *rd)/*{{{*/
{
  SQLRETURN status;
  struct freeDBC *dbcElement;
  oSes_t *ses;
  if (db == NULL) return NULL;
  ses = (oSes_t *) malloc (sizeof(oSes_t));
  if (!ses) 
  {
    dblog1(rd, "malloc failed");
    return NULL;
  }
  ses->db = db;
  ses->mode = AUTO_COMMIT;
  ses->stmthp = SQL_NULL_HANDLE;
  ses->datasizes = NULL;
  ses->needsClosing = 0;
  ses->rowp = NULL;
  ses->msg[0] = 0;
  ses->connhp = NULL;
  ses->next = NULL;
  if (db->bugs.QfreeDBCs && db->bugs.freeDBC)  // MySQL freeHandle workaround
  {
    dbcElement = db->bugs.freeDBC;
    ses->connhp = dbcElement->dbc;
    db->bugs.freeDBC = dbcElement->next;
    free(dbcElement);
  }
  else
  {
    status = SQLAllocHandle(SQL_HANDLE_DBC, db->envhp, &ses->connhp);
    ErrorCheck(status, SQL_HANDLE_ENV, db->envhp, db->msg,
        dblog1(rd, "odbc: DataBase alloc failed; are we out of memory?");
        free(ses);
        return NULL;,
        rd
        )
  }
  status = SQLSetConnectAttr(ses->connhp, SQL_ATTR_QUIET_MODE, NULL, 0);
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg,
      SQLFreeHandle (SQL_HANDLE_DBC, ses->connhp);
      free(ses);
      return NULL;,
      rd
      )
  status = SQLConnect(ses->connhp, db->DSN.cstring, db->DSN.length,
                                   db->UID.cstring, db->UID.length,
                                   db->PW.cstring, db->PW.length);
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg,
      DBCheckNSetIfServerGoneBad(db, SQL_HANDLE_DBC, ses->connhp, rd, 0);
      SQLFreeHandle (SQL_HANDLE_DBC, ses->connhp);
      free(ses);
      return NULL;,
      rd
      )
  db->number_of_sessions++;
//  dblog2(rd, "DBgetSession numberOfSess", db->number_of_sessions);
  return ses;
}/*}}}*/

static void
DBFlushStmt (oSes_t *ses, void *ctx)/*{{{*/
{
  if (ses == NULL) return;
//  if (ses->mode == MANUAL_COMMIT)
//  {
//    SQLRETURN status;
//    ses->mode = AUTO_COMMIT;
//    status = SQLEndTran(SQL_HANDLE_DBC, ses->connhp, SQL_ROLLBACK);
//    ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg, ;, ctx)
//  }
  if (ses->datasizes)
  {
    free(ses->datasizes);
    ses->datasizes = NULL;
  }
  if (ses->rowp)
  {
    free(ses->rowp);
    ses->rowp = NULL;
  }
  if (ses->stmthp != SQL_NULL_HANDLE)
  {
    SQLFreeHandle(SQL_HANDLE_STMT, ses->stmthp);
    ses->stmthp = SQL_NULL_HANDLE;
  }
  return;
}/*}}}*/

int
DBODBCExecuteSQL (oSes_t *ses, char *sql, void *ctx)/*{{{*/
{
  // dblog1(ctx, "Enter: DBODBCExecuteSQL");
  if (ses == NULL || sql == NULL) return DBError;
  SQLRETURN status;
  // dblog1(ctx, "Allocating handle");
  status = SQLAllocHandle(SQL_HANDLE_STMT, ses->connhp, &(ses->stmthp)); 
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_DBC, ses->connhp, ctx, 1);
      return DBError;,
      ctx
      )
  ses->needsClosing = 0;
  // dblog1(ctx, "Executing:");
  // dblog1(ctx, sql);
  status = SQLExecDirect(ses->stmthp, (SQLCHAR *) sql, SQL_NTS);
  // dblog1(ctx, "After SQLExecDirect");
  // dblog2(ctx, "status = ", (int)status);
  // dblog2(ctx, "SQL_SUCCESS = ", SQL_SUCCESS);
  // dblog2(ctx, "SQL_SUCCESS_WITH_INFO = ", SQL_SUCCESS_WITH_INFO);
  // dblog2(ctx, "SQL_ERROR = ", SQL_ERROR);
  // dblog2(ctx, "SQL_NEED_DATA = ", SQL_NEED_DATA);
  // dblog2(ctx, "SQL_STILL_EXECUTING = ", SQL_STILL_EXECUTING);
  // dblog2(ctx, "SQL_INVALID_HANDLE = ", SQL_INVALID_HANDLE);
  // dblog2(ctx, "SQL_NO_DATA = ", SQL_NO_DATA);
  
  if (status == SQL_NO_DATA)
  {
    SQLFreeHandle(SQL_HANDLE_STMT, ses->stmthp);
    ses->stmthp = SQL_NULL_HANDLE;
    return DBDml;
  }
  ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_STMT, ses->stmthp, ctx, 1);
      SQLFreeHandle(SQL_HANDLE_STMT, ses->stmthp);
      ses->stmthp = SQL_NULL_HANDLE;
      return DBError;,
      ctx
      )
  // dblog1(ctx, "Executed fine");
  ses->needsClosing = 1;
  status = SQLNumResultCols(ses->stmthp, &ses->cols);
  ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_STMT, ses->stmthp, ctx, 1);
      DBFlushStmt(ses,ctx);
      ses->stmthp = SQL_NULL_HANDLE;
      return DBError;,
      ctx
      )
  // dblog2(ctx, "SQLNumResultCols :", ses->cols);
  if (ses->cols > 0) return DBData;
  SQLCloseCursor(ses->stmthp);
  ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_STMT, ses->stmthp, ctx, 1);
      ses->needsClosing = 0;
      DBFlushStmt(ses,ctx);
      return DBError;,
      ctx
      )
  // dblog1(ctx, "Freeing handle");
  SQLFreeHandle(SQL_HANDLE_STMT, ses->stmthp);
  ses->stmthp = SQL_NULL_HANDLE;
  // dblog1(ctx, "Exit: DBODBCExecuteSQL");
  return DBDml;
}/*}}}*/

static void *
DBGetColumnInfo (oSes_t *ses, void *dump(void *, int, SQLSMALLINT, char *), 
                 void **columnCtx, void *ctx)/*{{{*/
{
  SQLSMALLINT i;
  SQLRETURN status;
  SQLSMALLINT colnamelength;
  int *datasizes;
  // dblog1(ctx,"Checking for NULL_HANDLE");
  if (ses->stmthp == SQL_NULL_HANDLE) return NULL;
  ses->datasizes = (int *) malloc((ses->cols+1) * sizeof (int));
  
  if (ses->datasizes == NULL) return NULL;
  datasizes = ses->datasizes;
  datasizes[0] = ses->cols;
  for (i=1; i <= ses->cols; i++)
  {
    // Get column data
    // SQLColAttribute with SQL_DESC_OCTET_LENGTH will do
    // Get column name
    status = SQLColAttribute(ses->stmthp, i, SQL_DESC_NAME, ses->msg,
                             MAXMSG - 1, &colnamelength, NULL);
    ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg,
        DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_STMT, ses->stmthp, ctx, 1);
        DBFlushStmt(ses,ctx);
        return NULL;,
        ctx
        )
    *columnCtx = dump(*columnCtx, i, colnamelength, ses->msg);
    // Get size of data
    status = SQLColAttribute(ses->stmthp, i, SQL_DESC_OCTET_LENGTH, 
                             NULL, 0, NULL, datasizes+i);
    ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg,
        DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_STMT, ses->stmthp, ctx, 1);
        DBFlushStmt(ses,ctx);
        return NULL;,
        ctx
        )
    // dblog2(ctx, "datasizes", datasizes[i]);
  }
  return *columnCtx;
}/*}}}*/

static int
DBGetRow (oSes_t *ses, void *dump(void *, SQLLEN, char *, unsigned int), 
          void **rowCtx, void *ctx)/*{{{*/
{
  unsigned int n;
  int i;
  SQLRETURN status;
  unsigned int size = MAXMSG; // 0; // <--- Hack to work with postgreSQL
  if (ses->stmthp == NULL) return DBEod;
  n = ses->datasizes[0];
//  dblog2(ctx, "DBGetRow n", n);
  if (!ses->rowp) 
  {
    for (i=1; i <= n; i++) size = MAX(ses->datasizes[i],size);
    ses->rowp = (char *) malloc(size+1+sizeof(SQLINTEGER) + MAXMSG);
//    dblog2(ctx, "DBGetRow size", size);
    if (!ses->rowp)
    {
      DBFlushStmt(ses, ctx);
      return DBError;
    }
    ses->rowpSize = size;
/*    for (i=1, size = n * sizeof(SQLLEN); i <= n; i++)
    {
      status = SQLBindCol(ses->stmthp, (SQLUSMALLINT) i, SQL_C_CHAR,
                              (SQLPOINTER) (ses->rowp+size), 
                              (SQLINTEGER) (ses->datasizes[i] + 1),
                              (SQLLEN *) (ses->rowp + (i * sizeof(SQLLEN))));
      ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg,
          DBCheckNSetIfServerGoneBad(ses->db, status, ctx, 1);
          DBFlushStmt(ses,ctx);
          return DBError;,
          ctx
          )
      size += ses->datasizes[i]+1;
    } */
  }
//  dblog1(ctx, "DBGetRow fetch");
  status = SQLFetch(ses->stmthp);
  if (status == SQL_NO_DATA)
  {
//    dblog1(ctx, "DBGetRow fetch NO DATA");
    DBFlushStmt(ses,ctx);
    return DBEod;
  }
  ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg,
        DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_STMT, ses->stmthp, ctx, 1);
        DBFlushStmt(ses,ctx);
        return DBError;,
        ctx
        )
//  for (i=1, size = 0; i < n; i++) size += ses->datasizes[i] + 1 + sizeof(SQLLEN);
//  dblog2(ctx, "DBGetRow get Data", size);
  SQLRETURN stat;
  char smallbuf[10];
  SQLSMALLINT smallbufLength = 0;
//    dblog2(ctx, "before n", n);
  for (i = 1; i <= n; i++)
  {
    status = SQLGetData(ses->stmthp, (SQLUSMALLINT) i, SQL_C_CHAR, 
                        (SQLPOINTER) (ses->rowp + sizeof(SQLINTEGER)), 
                        (SQLINTEGER) ses->rowpSize - 1 - sizeof(SQLINTEGER), 
                        (SQLINTEGER *) ses->rowp);
    switch (status)
    { 
      case SQL_SUCCESS:
        *rowCtx = dump(*rowCtx, *((SQLINTEGER *) ses->rowp),
                       ses->rowp + sizeof(SQLINTEGER), 0);
//        if (*((SQLINTEGER *) ses->rowp) == SQL_NULL_DATA) 
//        {
//          dblog1(ctx, "data was NULL");
//        }
//        else
//        {
//          dblog1(ctx,ses->rowp+sizeof(SQLINTEGER));
//        }
        break;
      case SQL_SUCCESS_WITH_INFO:
        stat = SQLGetDiagField (SQL_HANDLE_STMT, ses->stmthp, 1, SQL_DIAG_SQLSTATE, 
                                  smallbuf, 9, &smallbufLength);
        if (stat == SQL_SUCCESS && !strncmp(smallbuf, "01004", 5))
        {
          *rowCtx = dump(*rowCtx, *((SQLINTEGER *) ses->rowp),
                         ses->rowp + sizeof(SQLINTEGER), ses->rowpSize - 1 - sizeof(SQLINTEGER) - 1);
          continue;
        }
        // NO break on purpose;
      default:
        ErrorCheck(status, SQL_HANDLE_STMT, ses->stmthp, ses->msg, 
            DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_STMT, ses->stmthp, ctx, 1);
            DBFlushStmt(ses,ctx);
            return DBError;,
            ctx)
        break;
    }
  }
//  dblog1(ctx, "DBGetRow DONE");
  return DBData;
}/*}}}*/

uintptr_t 
DBODBCTransStart (oSes_t *ses, void *ctx)/*{{{*/
{
  SQLRETURN status;
  if (ses == NULL || ses->mode == MANUAL_COMMIT) return DBError;
  status = SQLSetConnectAttr(ses->connhp, SQL_ATTR_AUTOCOMMIT, SQL_AUTOCOMMIT_OFF, 0);
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_DBC, ses->connhp, ctx, 1);
      return DBError;,
      ctx)
  ses->mode = MANUAL_COMMIT;
  return DBDml;
}/*}}}*/

uintptr_t
DBODBCTransCommit (oSes_t *ses, void *ctx)/*{{{*/
{
  SQLRETURN status;
  if (ses == NULL) return DBError;
  if (ses->mode == AUTO_COMMIT) 
  {
    DBFlushStmt(ses,ctx);
    return DBError;
  }
  ses->mode = AUTO_COMMIT;
  status = SQLSetConnectAttr(ses->connhp, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER) SQL_AUTOCOMMIT_ON, 0);
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_DBC, ses->connhp, ctx, 1);
      DBFlushStmt(ses,ctx);
      return DBError;,
      ctx
      )
  return DBDml;
}/*}}}*/

uintptr_t 
DBODBCTransRollBack(oSes_t *ses, void *ctx)/*{{{*/
{
  SQLRETURN status;
  if (ses == NULL) return DBError;
  if (ses->mode == AUTO_COMMIT) 
  {
    DBFlushStmt(ses,ctx);
    return DBError;
  }
  status = SQLEndTran(SQL_HANDLE_DBC, ses->connhp, SQL_ROLLBACK);
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_DBC, ses->connhp, ctx, 1);
      DBFlushStmt(ses,ctx);
      return DBError;,
      ctx
      )
  ses->mode = AUTO_COMMIT;
  status = SQLSetConnectAttr(ses->connhp, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER) SQL_AUTOCOMMIT_ON, 0);
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg,
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_DBC, ses->connhp, ctx, 1);
      DBFlushStmt(ses,ctx);
      return DBError;,
      ctx
      )
  return DBDml;
}/*}}}*/

static uintptr_t
DBReturnSession (oSes_t *ses, void *ctx)/*{{{*/
{
  SQLRETURN status;
  oDb_t *db;
  unsigned char should_we_shutdown;
  unsigned int number_of_sessions;
  if (ses == NULL) return DBError;
  if (ses->stmthp != SQL_NULL_HANDLE || ses->mode == MANUAL_COMMIT)
  { // A transaction is open
    DBODBCTransRollBack(ses,ctx);
    dblog1(ctx, "ODBC Driver: DBReturnSession, a transaction was in flight");
  }
  status = SQLDisconnect(ses->connhp);
  ErrorCheck(status, SQL_HANDLE_DBC, ses->connhp, ses->msg, 
      DBCheckNSetIfServerGoneBad(ses->db, SQL_HANDLE_DBC, ses->connhp, ctx, 0);,
      ctx)
  ses->db->number_of_sessions--;
  should_we_shutdown = ses->db->about_to_shutdown;
  number_of_sessions = ses->db->number_of_sessions;
  struct freeDBC *dbcElement;
  if (ses->db->bugs.QfreeDBCs)
  {
//    dblog1(ctx,"Not freeing Connection handle");
    dbcElement = (struct freeDBC *) malloc(sizeof(struct freeDBC));
    if (dbcElement) // Memory leak intended (we are already out of mem)
    {
      dbcElement->dbc = ses->connhp;
      dbcElement->next = ses->db->bugs.freeDBC;
      ses->db->bugs.freeDBC = dbcElement;
    }
  }
  else
  {
//    dblog1(ctx,"Freeing Connection handle");
    status = SQLFreeHandle(SQL_HANDLE_DBC, ses->connhp);
  }
  db = ses->db;
  free(ses);
  if (should_we_shutdown && number_of_sessions == 0)
  {
    DBShutDown(db, ctx);
  }
  return DBEod;
}/*}}}*/

uintptr_t
apsmlODBCDropSession(oSes_t *ses, void *rd)/*{{{*/
{
  dbOraData *dbdata;
  oSes_t *tmpses, *rses;
  int dbid, i;
  // int numberOfSess;
  oDb_t *db;
  if (ses == NULL || rd == NULL) return DBError;
  dbid = ses->db->dbid;
  db = ses->db;
  dbdata = (dbOraData *) getDbData(dbid, rd);
  if (dbdata == NULL) return DBError;
  if (dbdata->dbSessions == ses)
  {
    dbdata->dbSessions = ses->next;
  }
  else
  {
    rses = (oSes_t *) dbdata->dbSessions;
    tmpses = rses;
    while (tmpses != NULL)
    {
      if (tmpses == ses)
      {
        rses->next = tmpses->next;
        break;
      }
      rses = tmpses;
      tmpses = tmpses->next;
    }
  }
  dbdata->depth--;
  db_conf *dbc = (db_conf *) apsmlGetDBData(dbid, rd);
  lock_thread(dbc->tlock);
//  dblog2(rd, "numberOfSess", db->number_of_sessions);
  if (dbdata->theOne)
  {
    ses->next = NULL;
    tmpses = NULL;
    for (rses = dbdata->freeSessions; rses; rses = rses->next)
    {
      tmpses = rses;
    }
    if (tmpses)
    {
      tmpses->next = ses;
    }
    else
    {
      dbdata->freeSessions = ses;
    }
    if (!dbdata->dbSessions)
    {
      dbdata->theOne = 0;
      ses = dbdata->freeSessions;
      dbdata->freeSessions = NULL;
      if (db->freeSessionsGlobal)
      {
        while ((rses = db->freeSessionsGlobal))
        {
          db->freeSessionsGlobal = rses->next;
          // numberOfSess = db->number_of_sessions;
          DBReturnSession(rses, rd);
        }
      }
      db->freeSessionsGlobal = ses;
      i = dbc->maxdepth;
      rses = db->freeSessionsGlobal;
      tmpses = rses;
      while(rses)
      {
        if (i)
        {
          tmpses = rses;
          rses = rses->next;
          i--;
          continue;
        }
        ses = rses;
        rses = rses->next;
        // numberOfSess = db->number_of_sessions;
        DBReturnSession(ses,rd);
      }
      if (tmpses) tmpses->next = NULL;
      if (db->number_of_sessions == dbc->maxdepth)
      {
        rses = db->freeSessionsGlobal;
        while(rses)
        {
          ses = rses;
          rses = rses->next;
          // numberOfSess = db->number_of_sessions;
          DBReturnSession(ses,rd);
        }
        db->freeSessionsGlobal = NULL;
      }
      broadcast_cond(dbc->cvar);
    }
  }
  else
  {
    // numberOfSess = db->number_of_sessions;
    DBReturnSession(ses,rd);
    broadcast_cond(dbc->cvar);
  }
  unlock_thread(dbc->tlock);
  if (dbdata->dbSessions == NULL) 
  {
    removeDbData(dbid, rd);
    free(dbdata);
  }
//  dblog2(rd, "DBReturn numberOfSess", numberOfSess);
  return DBEod;
}/*}}}*/

oSes_t *
apsmlODBCGetSession(int dbid, void *rd)/*{{{*/
{
  oSes_t *ses;
  oDb_t *db;
  int i;
  dbOraData *dbdata = (dbOraData *) getDbData(dbid, rd);
  if (!dbdata) 
  {
    dbdata = (dbOraData *) malloc(sizeof (dbOraData));
    if (!dbdata) return NULL;
    dbdata->freeSessions = NULL;
    dbdata->dbSessions = NULL;
    dbdata->theOne = 0;
    dbdata->depth = 0;
    if (putDbData(dbid, dbdata, rd)) 
    {
      free(dbdata);
      return NULL;
    }
  }
  if (dbdata->freeSessions)
  {
    dbdata->depth++;
    ses = dbdata->freeSessions;
    dbdata->freeSessions = ses->next;
    return ses;
  }
  db_conf *dbc = (db_conf *) apsmlGetDBData(dbid,rd);
  if (dbc == NULL)
  {
    dblog1(rd, "Database not configred");
    return NULL;
  }
  if (dbdata->depth >= dbc->maxdepth) 
  {
    return (oSes_t *) 1;
  }
  lock_thread(dbc->tlock);
  if (!dbc->dbspec)
  {
    if (!dbc->DSN || !dbc->username || !dbc->password || 
         dbc->maxdepth < 1)
    {
      unlock_thread(dbc->tlock);
      dblog1(rd, 
           "One or more of DSN, UserName, PassWord and SessionMaxDepth not set");
      return NULL;
    }
    dblog1(rd, "Initializing database connection");
    dbc->dbspec = DBinitConn(rd, (SQLCHAR *) dbc->DSN, (SQLCHAR *) dbc->username, 
                                    (SQLCHAR *) dbc->password, dbid);
//    dblog1(rd, "Database initialization call done");
  }
  if (!dbc->dbspec)
  {
    unlock_thread(dbc->tlock);
    dblog1(rd, "Database did not start");
    return NULL;
  }
  db = dbc->dbspec;
  if (db->number_of_sessions == 0)
  {
    for (i = 0; i < dbc->maxdepth; i++)
    {
      ses = DBgetSession(dbc->dbspec, rd);
      if (ses == NULL)
      {
        while (dbdata->freeSessions)
        {
          ses = ((oSes_t *)(dbdata->freeSessions))->next;
          DBReturnSession(dbdata->freeSessions,rd);
          dbdata->freeSessions = ses;
        }
        dblog1(rd, "Could not get session");
        unlock_thread(dbc->tlock);
        return NULL;
      }
      ses->next = dbdata->freeSessions;
      dbdata->freeSessions = ses;
    }
    dbdata->depth = 1;
    ses = dbdata->freeSessions;
    dbdata->freeSessions = ses->next;
    ses->next = NULL;
    dbdata->dbSessions = ses;
    dbdata->theOne = 1;
    unlock_thread(dbc->tlock);
    return ses;
  }
  else
  {
    if (db->freeSessionsGlobal)
    {
      dbdata->theOne = 1;
      ses = db->freeSessionsGlobal;
      db->freeSessionsGlobal = NULL;
      dbdata->freeSessions = ses->next;
      ses->next = dbdata->dbSessions;
      dbdata->dbSessions = ses;
      dbdata->depth++;
      unlock_thread(dbc->tlock);
      return ses;
    }
    else
    {
      ses = DBgetSession(db,rd);
      if (ses)
      {
        ses->next = dbdata->dbSessions;
        dbdata->dbSessions = ses;
        dbdata->depth++;
        unlock_thread(dbc->tlock);
        return ses;
      }
      else 
      {
        dblog1(rd, "Could not get session");
        wait_cond(dbc->cvar);
        unlock_thread(dbc->tlock);
        return apsmlODBCGetSession(dbid, rd);
      }
    }
  }
  dblog1(rd, "ODBC driver: End of apsmlGetSession reached. This is not suppose to happend");
  unlock_thread(dbc->tlock);
  return NULL;
}/*}}}*/

static void
apsmlDbCleanUpReq(void *rd, void *dbdata1)/*{{{*/
{
  oSes_t *ses;
  dbOraData *dbdata = (dbOraData *) dbdata1;
  if (rd == NULL || dbdata == NULL) return;
  while ((ses = dbdata->dbSessions))
  {
    apsmlODBCDropSession(ses, rd);
  }
  return;
}/*}}}*/

void 
apsmlORAChildInit(void *c1, int num, void *pool, void *server)
{
  return;
}

int 
apsmlODBCSetVal (int i, void *rd, int pos, void *val)/*{{{*/
{
  int id;
  char *sd, *target;
  db_conf *cd;
//  dblog1(rd, "apsmlORASetVal");
  cd = (db_conf *) apsmlGetDBData (i,rd);
  if (cd == NULL) 
  {
    cd = (db_conf *) malloc (sizeof (db_conf));
    if (!cd) return 2;
    cd->username = NULL;
    cd->password = NULL;
    cd->DSN = NULL;
    cd->maxdepth = 0;
    cd->dbspec = NULL;
    if (create_thread_lock(&(cd->tlock), rd))
    {
      free(cd);
      return 2;
    }
    if (create_cond_variable(&(cd->cvar), cd->tlock, rd))
    {
      destroy_thread_lock(cd->tlock);
      free(cd);
      return 2;
    }
    if (apsmlPutDBData (i,(void *) cd, apsmlORAChildInit, DBShutDownWconf, apsmlDbCleanUpReq, rd))
    {
      destroy_thread_lock(cd->tlock);
      free(cd);
      return 2;
    }
    cd = (db_conf *) apsmlGetDBData (i,rd);
  }
  switch (pos)
  {
    case 5:
      id = (int) val;
      cd->maxdepth = id;
      break;
    case 2:
    case 3:
    case 4:
      sd = (char *) val;
      target = (char *) malloc (strlen (sd)+1);
      if (!target) return 2;
      strcpy(target, sd);
      switch (pos)
      {
        case 2:
          if (cd->username) free(cd->username);
          cd->username = target;
          break;
        case 3:
          if (cd->password) free(cd->password);
          cd->password = target;
          break;
        case 4:
          if (cd->DSN) free(cd->DSN);
          cd->DSN = target;
          break;
      }
      break;
    default:
      return 1;
      break;
  }
  return 0;
}/*}}}*/


typedef struct/*{{{*/
{
  Region rList1Addr;
  Region rStringAddr;
  Region rList2Addr;
  uintptr_t *list1;
  uintptr_t *list2;
} cNames_t;/*}}}*/

static void *
dumpCNames (void *ctx1, int pos, SQLSMALLINT length, char *data)/*{{{*/
{
  String rs;
  uintptr_t *pair;
  cNames_t *ctx = (cNames_t *) ctx1;
  rs = convertBinStringToML(ctx->rStringAddr, length, data);
  allocRecordML(ctx->rList1Addr, 2, pair);
  first(pair) = (uintptr_t) rs;
  second(pair) = (uintptr_t) ctx->list1;
  makeCONS(pair, ctx->list1);
  return ctx;
}/*}}}*/

uintptr_t
apsmlODBCGetCNames(Region rList1Addr, Region rStringAddr, oSes_t *ses, void *rd)/*{{{*/
{
  cNames_t cn1;
  cNames_t *cn = &cn1;
  cn->rList1Addr = rList1Addr;
  cn->rStringAddr = rStringAddr;
  cn->rList2Addr = NULL;
  makeNIL(cn->list1);
  if (DBGetColumnInfo(ses, dumpCNames, (void **) &cn, rd) == NULL)
  {
    raise_overflow();
    return (uintptr_t) cn1.list1;
  }
  return (uintptr_t) cn1.list1;
}/*}}}*/

static void *
dumpRows(void *ctx1, SQLLEN data1, char *data2, unsigned int next)/*{{{*/
{
  String rs;
  uintptr_t *pair, *pair2;
  cNames_t *ctx = (cNames_t *) ctx1;
  if (next)
  {
    allocRecordML(ctx->rList2Addr, 2, pair2);
    rs = convertStringToML(ctx->rStringAddr, data2);
    first(pair2) = (uintptr_t) rs;
    second(pair2) = (uintptr_t) ctx->list2;
    makeCONS(pair2, ctx->list2);
    return ctx;
  }
  else
  {
    allocRecordML(ctx->rList1Addr, 2, pair);
    if (data1 == SQL_NULL_DATA)
    {
      makeNIL(ctx->list2);
    }
    else 
    {
      allocRecordML(ctx->rList2Addr, 2, pair2);
      rs = convertStringToML(ctx->rStringAddr, data2);
      first(pair2) = (uintptr_t) rs;
      second(pair2) = (uintptr_t) ctx->list2;
      makeCONS(pair2, ctx->list2);
    }
    first(pair) = (uintptr_t) ctx->list2;
    makeNIL(ctx->list2);
    second(pair) = (uintptr_t) ctx->list1;
    makeCONS(pair, ctx->list1);
  }
  return ctx;
}/*}}}*/

uintptr_t
apsmlODBCGetRow(uintptr_t vAddrPair, Region rAddrL1Pairs, Region rAddrL2Pairs, Region rAddrString, 
            oSes_t *ses, void *rd)/*{{{*/
{
  cNames_t cn1;
  uintptr_t res;
  cNames_t *cn = &cn1;
  cn->rList1Addr = rAddrL1Pairs;
  cn->rStringAddr = rAddrString;
  cn->rList2Addr = rAddrL2Pairs;
  makeNIL(cn->list1);
  makeNIL(cn->list2);
  res = DBGetRow(ses, dumpRows, (void **) &cn, rd);
  first(vAddrPair) = (uintptr_t) cn1.list1;
  second(vAddrPair) = res;
  return vAddrPair;
}/*}}}*/

