/*----------------------------------------------------------------*
 *                        Profiling                               *
 *----------------------------------------------------------------*/

/* Only include this file if PROFILING is defined...  The queueMark
 * function should be defined if PROFILING is not defined, however;
 * look at the bottom. */

#include <stdio.h>
#include <signal.h>      // used by signal
#include <sys/time.h>    // used by setitimer

#include "Profiling.h"
#include "Region.h"
#include "Tagging.h"
#include "String.h"
#include "Exception.h"

#ifdef PROFILING

/*----------------------------------------------------------------*
 * Global declarations                                            *
 *----------------------------------------------------------------*/
int *stackBot;
int timeToProfile;
int maxStack;         // max. stack size from check_stack
int *maxStackP=NULL;  // Max. stack addr. from ProfileTick
int tempAntal; 
int tellTime;         /* 1, if the next profile tick should print out the
		       * current time - 0 otherwise */

struct itimerval rttimer;    
struct itimerval old_rttimer;
int    profileON = TRUE; /* if false profiling is not started after a profileTick. */

char * freeProfiling;  /* Pointer to free-chunk of mem. to profiling data. */
int freeProfilingRest; /* Number of bytes left in freeProfiling-chunk.     */

TickList * firstTick; /* Pointer to data for the first tick. */
TickList * lastTick;  /* Pointer to data for the last tick. */

/* The following two global arrays are used as hash tables during 
 * a profile tick. */
RegionListHashList * regionListHashTable[REGION_LIST_HASH_TABLE_SIZE];  /* Used as hash table into a region list. */
ObjectListHashList * objectListHashTable[OBJECT_LIST_HASH_TABLE_SIZE];  /* Used as hash table into an object list. */

ProfTabList * profHashTab[PROF_HASH_TABLE_SIZE];  /* Hash table for information collected during execution */

int profTabCountDebug = 0;


unsigned int numberOfTics=0; /* Number of profilings so far. */

unsigned int lastCpuTime=0; /* CPU time after last tick. */
unsigned int cpuTimeAcc=0;  /* Used time by program excl. profiling. */

int noTimer =                                  /* Profile with a constant number of function calls. */
    ITIMER_REAL+ITIMER_VIRTUAL+ITIMER_PROF;    /* A number different from the other constants.      */
int profType = ITIMER_VIRTUAL; /* Type of profiling to use */
int signalType = SIGVTALRM;    /* Signal to catch depending on profType. */
int profNo = 10000;   
int microsec = 0;
int sec = 1;
int verboseProfileTick = 0;
int printProfileTab = 0;
int exportProfileDatafile = 1;
int showStat = 0;

char  logName[100]="profile.rp";   /* Name of log file to use. */
FILE* logFile;
FILE* logFile_xx;
char  logName_xx[100]="profile.rp";   /* Name of log file to use. */
int noOfTickInFile = 0;
char prgName[100];

int doing_prof = 0;
int raised_exn_interupt_prof = 0;
int raised_exn_overflow_prof = 0;


static unsigned int max(unsigned int a, unsigned int b) {
  return (a<b)?b:a;
}

static unsigned int min(unsigned int a, unsigned int b) {
  return (a<b)?a:b;
}

/*--------------------------------------
 * Hash table to hold profiling table
 * mapping region ids to objects of type
 * profTabList (see Profiling.h)
 *--------------------------------------*/

void initializeProfTab(void) {
  int i;
  /*  printf("Initializing profTab\n"); */
  for (i = 0 ; i < PROF_HASH_TABLE_SIZE ; i++) 
    profHashTab[i]=NULL;
  return;
}

int profSize(ProfTabList* p) {
  int count = 0;
  for ( ; p != NULL; p=p->next) {
    count++ ;
  }
  return count;
}

int profTabSize(void) {
  int count, i;
  ProfTabList* p;
  for (count = 0, i = 0 ; i < PROF_HASH_TABLE_SIZE ; i++)
    for (p=profHashTab[i]; p != NULL; p=p->next, count++) {}
  return count;
}

ProfTabList* profTabListInsertAndInitialize(ProfTabList* p, int regionId) {
  ProfTabList* pNew;
  /*  checkProfTab("profTabListInsertAndInitialize.enter"); */

  profTabCountDebug ++;
  /*  
      printf("Entering profTabListInsertAndInitialize; regionId = %d, profSize = %d, count = %d\n", 
	 regionId, profSize(p), profTabCountDebug);
  */
  pNew = (ProfTabList*)allocMemProfiling_xx(sizeof(ProfTabList));
  if (pNew == (ProfTabList*) -1) {
    perror("profTabListInsertAndInitialize error\n");
    exit(-1);
  }
  pNew->regionId=regionId;
  pNew->noOfPages=0;
  pNew->maxNoOfPages=0;
  pNew->allocNow=0;
  pNew->maxAlloc=0;
  pNew->next=p;
  /*  checkProfTab("profTabListInsertAndInitialize.exit"); */
  return pNew;
}

void profTabMaybeIncrMaxNoOfPages(int regionId) {
  ProfTabList* p;
  int index;

  /*  checkProfTab("profTabMaybeIncrMaxNoOfPages.enter"); */

  index = profHashTabIndex(regionId);

  for (p=profHashTab[index]; p != NULL; p=p->next)
    if (p->regionId == regionId) {
      if (p->noOfPages >= p->maxNoOfPages) p->maxNoOfPages = p->noOfPages;
      /* checkProfTab("profTabMaybeIncrMaxNoOfPages.exit1"); */
      return;
    };
  p = profTabListInsertAndInitialize(profHashTab[index], regionId);
  profHashTab[index] = p;
  p->maxNoOfPages = 1;
  p->noOfPages = 1;
  /* checkProfTab("profTabMaybeIncrMaxNoOfPages.exit2"); */
  return;
}

int profTabGetNoOfPages(int regionId) {
  ProfTabList* p;
  /* checkProfTab("profTabGetNoOfPages.enter"); */
  for (p=profHashTab[profHashTabIndex(regionId)]; p != NULL; p=p->next)
    if (p->regionId == regionId) {
      /* checkProfTab("profTabGetNoOfPages.exit1"); */
      return p->noOfPages;
    }
  /* checkProfTab("profTabGetNoOfPages.exit2"); */
  return 0;
}

void profTabIncrNoOfPages(int regionId, int i) {
  ProfTabList* p;
  int index;
  /* checkProfTab("profTabIncrNoOfPages.enter"); */

  index = profHashTabIndex(regionId);
  for (p=profHashTab[index]; p != NULL; p=p->next)
    if (p->regionId == regionId) {
      p->noOfPages = p->noOfPages + i;
      /* checkProfTab("profTabIncrNoOfPages.exit1"); */
      return;
    };
  p = profTabListInsertAndInitialize(profHashTab[index], regionId);
  profHashTab[index] = p;
  p->maxNoOfPages = 1;
  p->noOfPages = 1;
  /* checkProfTab("profTabIncrNoOfPages.exit2"); */
  return;
}

void profTabDecrNoOfPages(int regionId, int i) {
  ProfTabList* p;
  /* checkProfTab("profTabDecrNoOfPages.enter"); */
  for (p=profHashTab[profHashTabIndex(regionId)]; p != NULL; p=p->next)
    if (p->regionId == regionId) {
      p->noOfPages = p->noOfPages - i;
      /* checkProfTab("profTabDecrNoOfPages.exit"); */
      return;
    };
  printf("regionId is %d\n", regionId);
  perror("profTabDecrNoOfPages error"); 
  exit(-1);
}

void profTabDecrAllocNow(int regionId, int i, char *s) {
  ProfTabList* p;
  /* checkProfTab("profTabDecrAllocNow.enter"); */
  for (p=profHashTab[profHashTabIndex(regionId)]; p != NULL; p=p->next)
    if (p->regionId == regionId) {
      p->allocNow = p->allocNow - i;
      /* checkProfTab("profTabDecrAllocNow.exit"); */
      return;
    };
  printf("Error.%s: regionId %d do not exist in profiling table\n", s, regionId);
  printf("profTabCountDebug = %d, profTabSize = %d\n", profTabCountDebug, 
	 profTabSize());
  printProfTab();
  perror("profTabDecrAllocNow error\n");
  exit(-1);
}

void profTabIncrAllocNow(int regionId, int i) {
  ProfTabList* p;
  int index;
  /* checkProfTab("profTabIncrAllocNow.enter"); */

  index = profHashTabIndex(regionId);
  for (p=profHashTab[index]; p != NULL; p=p->next) {
    if (p->regionId == regionId) {
      p->allocNow += i;
      if (p->allocNow > p->maxAlloc) p->maxAlloc = p->allocNow;
      /* checkProfTab("profTabIncrAllocNow.exit1"); */
      return;
    }
  }
  p = profTabListInsertAndInitialize(profHashTab[index], regionId);
  profHashTab[index] = p;
  p->allocNow += i;
  if (p->allocNow > p->maxAlloc) p->maxAlloc = p->allocNow;
  /* checkProfTab("profTabIncrAllocNow.exit2"); */
  return;
}


/* ---------------------------------------------------------- *
 * Hash table to hold LOCAL region map. Hash table used 
 * locally during a profile tick to make lookup fast.
 * ---------------------------------------------------------- */

void initializeRegionListTable(void) {
  int i;
  for (i = 0 ; i < REGION_LIST_HASH_TABLE_SIZE; i++ )
    regionListHashTable[i] = NULL;
  return;
}

void insertRegionListTable(int regionId, RegionList* rl) {
  RegionListHashList* p;
  int index;
  index = regionListHashTabIndex(regionId);
  for (p=regionListHashTable[index]; p != NULL; p=p->next)
    if (p->regionId == regionId) {
      p->rl = rl;
      return;
    };
  p = (RegionListHashList*)allocMemProfiling_xx(sizeof(RegionListHashList));     /* create element */
  if (p == (RegionListHashList*) -1) {
    perror("insertRegionListTable error\n");
    exit(-1);
  }
  p->regionId = regionId;
  p->rl = rl;
  p->next = regionListHashTable[index];
  regionListHashTable[index] = p;         /* update hash table; new element is stored in front */
  return;
}

RegionList* lookupRegionListTable(int regionId) {
  RegionListHashList* p;
  int index;
  index = regionListHashTabIndex(regionId);
  for (p=regionListHashTable[index]; p != NULL; p=p->next)
    if (p->regionId == regionId) return p->rl;
  return NULL;
}

/* ---------------------------------------------------------- *
 * Hash table to hold LOCAL object map. The hash table is used 
 * locally during a profile tick to make lookup fast.
 * ---------------------------------------------------------- */

void initializeObjectListTable(void) {
  int i;
  for (i = 0; i < OBJECT_LIST_HASH_TABLE_SIZE; i++)
    objectListHashTable[i] = NULL;
  return;
}

void insertObjectListTable(int atId, ObjectList* ol) {
  ObjectListHashList* p;
  int index;
  index = objectListHashTabIndex(atId);
  for (p=objectListHashTable[index]; p != NULL; p=p->next)
    if (p->atId == atId) {
      p->ol = ol;
      return;
    };
  p = (ObjectListHashList*)allocMemProfiling_xx(sizeof(ObjectListHashList));   /* create element */
  if (p == (ObjectListHashList*) -1) {
    perror("insertObjectListTable error\n");
    exit(-1);
  }
  p->atId = atId;
  p->ol = ol;
  p->next = objectListHashTable[index];
  objectListHashTable[index] = p;         /* update hash table; new element is stored in front */
  return;
}
  
ObjectList* lookupObjectListTable(int atId) {
  ObjectListHashList* p;
  int index;
  index = objectListHashTabIndex(atId);
  for (p=objectListHashTable[index]; p != NULL; p=p->next)
    if (p->atId == atId) return p->ol;
  return NULL;
}

/*----------------------------------------------------------------------*
 *                        Statistical operations.                       *
 *----------------------------------------------------------------------*/

/* This function sets the flags 'tellTime' so that next time
   a tick is made, the time is printed on stdout */

void 
queueMarkProf(StringDesc *str, int pPoint)
{
    tellTime = 1;
    fprintf(stderr,"Reached \"%s\"\n", str->data);
    return;
}

/* Calculate the allocated and used space in a region. */
/* All instantiated regions with this region name is       */
/* calculated as one region.                               */
void 
AllocatedSpaceInARegion(Ro *rp)
{ 
  unsigned int n;

  n = profTabGetNoOfPages(rp->regionId) * ALLOCATABLE_WORDS_IN_REGION_PAGE * 4;
  fprintf(stderr,"    Allocated bytes in region %5d: %5d\n",rp->regionId, n);
  return;
}

/* Prints all pages in the region. */
void 
PrintRegion(Ro* rp)
{ 
  int i;
  Klump *ptr;
  
  if (rp!=NULL)
    {
      fprintf(stderr,"\nAddress of Ro %0x, First free word %0x, Border of region %0x\n     ",rp,rp->a,rp->b);
      for ( ptr = rp->fp , i = 1 ; ptr ; ptr = ptr->k.n , i++ ) 
	{
	  fprintf(stderr,"-->Page%2d:%d",i,ptr);
	  if (i%3 == 0)
	    fprintf(stderr,"\n     ");      
	}
      fprintf(stderr,"\n");
    }
}

void 
resetProfiler() 
{
  outputProfilePre();
  initializeProfTab();
  lastCpuTime = (unsigned int)clock();
  if (profType == noTimer)
    {
      timeToProfile = 1;
    }
  else 
    {
      timeToProfile = 0;
      rttimer.it_value.tv_sec = sec;         /* Time in seconds to first tick. */
      rttimer.it_value.tv_usec = microsec;   /* Time in microseconds to first tick. */
      rttimer.it_interval.tv_sec = 0;        /* Time in seconds between succeding ticks. */
      rttimer.it_interval.tv_usec = 0;       /* Time in microseconds between succeding ticks. */
      
      signal(signalType, AlarmHandler);
      
      profiling_on(); 
    }

  if (verboseProfileTick) 
    {
      fprintf(stderr,  "---------------------Profiling-Enabled---------------------\n");
      if (profType == noTimer) 
	{
	  fprintf(stderr," The profile timer is turned off; a profile tick occurs\n");
	  fprintf(stderr,"every %dth entrance to a function.\n", profNo);
	}
      if (profType == ITIMER_REAL)
	fprintf(stderr," The profile timer (unix real timer) is turned on.\n");
      if (profType == ITIMER_VIRTUAL)
	fprintf(stderr," The profile timer (unix virtual timer) is turned on.\n");
      if (profType == ITIMER_PROF)
	fprintf(stderr," The profile timer (unix profile timer) is turned on.\n");
      if (microsec != 0 && profType != noTimer)
	fprintf(stderr," A profile tick occurs every %dth microsecond.\n", microsec);
      if (sec != 0 && profType != noTimer) 
	fprintf(stderr," A profile tick occurs every %dth second.\n", sec);
      if (exportProfileDatafile) 
	fprintf(stderr," Profiling data is exported to file %s.\n", logName);
      else
	fprintf(stderr," No profiling data is exported.\n");
      fprintf(stderr,  "-----------------------------------------------------------\n");
    }
  return;
}

void 
checkProfTab(char* s) 
{
  int i;
  ProfTabList* p;
  for ( i = 0 ; i < PROF_HASH_TABLE_SIZE ; i++ ) 
    for ( p = profHashTab[i] ; p ; p = p->next )
      if ( p->regionId > 1000000 ) 
	{
	  printProfTab();
	  printf("Mysterious regionId (%d) in ProfTab: %s\n", p->regionId, s);
	  exit(-1);
	}
}

void 
printProfTab() 
{
  int i;
  int noOfPagesTab, maxNoOfPagesTab;
  int allocNowTab, maxAllocTab;
  int noOfPagesTot, maxNoOfPagesTot;
  int allocNowTot, maxAllocTot;
  ProfTabList* p;

  noOfPagesTot = 0;
  maxNoOfPagesTot = 0;
  allocNowTot = 0;
  maxAllocTot = 0;

  fprintf(stderr,"\n\nPRINTING PROFILING TABLE.\n");
  for ( i = 0 ; i < PROF_HASH_TABLE_SIZE ; i++ ) 
    for (p=profHashTab[i];p!=NULL;p=p->next) {
      noOfPagesTab = p->noOfPages;
      noOfPagesTot += noOfPagesTab;
      maxNoOfPagesTab = p->maxNoOfPages;
      maxNoOfPagesTot += maxNoOfPagesTab;
      allocNowTab = p->allocNow;
      allocNowTot += allocNowTab;
      maxAllocTab = p->maxAlloc;
      maxAllocTot += maxAllocTab;
      /*      if (maxNoOfPagesTab)  */
	fprintf(stderr,"    profTab[rId%5d]: noOfPages = %8d, maxNoOfPages = %8d, allocNow = %8d, maxAlloc = %8d\n",
		p->regionId, noOfPagesTab, maxNoOfPagesTab, allocNowTab*4, maxAllocTab*4);
    }
  fprintf(stderr,      "    ---------------------------------------------------------------------------------------------------\n");
  fprintf(stderr,      "                          %8d     SUM OF MAX: %8d         Bytes: %8d      Bytes: %8d\n",
	  noOfPagesTot, maxNoOfPagesTot, allocNowTot*4, maxAllocTot*4);
  fprintf(stderr,      "    ===================================================================================================\n");

}

void 
Statistics()
{ 
  Klump *ptr;
  int i,ii;
  double Mb = 1024.0*1024.0;

  if (showStat) {
    fprintf(stderr,"\n*************Region statistics***************\n");

    if (printProfileTab) printProfTab();

    /*    fprintf(stderr,"  Size of finite region descriptor: %d bytes\n",sizeof(FiniteRegionDesc)); */
    fprintf(stderr,"\nMALLOC\n");
    fprintf(stderr,"  Number of calls to malloc for regions: %d\n",callsOfSbrk);
    fprintf(stderr,"  Alloc. in each malloc call: %d bytes\n", BYTES_ALLOC_BY_SBRK);
    fprintf(stderr,"  Total allocation by malloc: %d bytes (%.1fMb)\n", BYTES_ALLOC_BY_SBRK*callsOfSbrk,
	    (BYTES_ALLOC_BY_SBRK*callsOfSbrk)/Mb );
    
    fprintf(stderr,"\nREGION PAGES\n");
    fprintf(stderr,"  Size of one page: %d bytes\n",ALLOCATABLE_WORDS_IN_REGION_PAGE*4);
    fprintf(stderr,"  Max number of allocated pages: %d\n",maxNoOfPages);
    fprintf(stderr,"  Number of allocated pages now: %d\n",noOfPages);
    fprintf(stderr,"  Max space for region pages: %d bytes (%.1fMb)\n", 
	    maxNoOfPages*ALLOCATABLE_WORDS_IN_REGION_PAGE*4, (maxNoOfPages*ALLOCATABLE_WORDS_IN_REGION_PAGE*4)/Mb);
    
    fprintf(stderr,"\nINFINITE REGIONS\n");
    /*    fprintf(stderr,"  Size of infinite reg. desc. (incl. prof info): %d bytes\n",sizeRo*4); */
    fprintf(stderr,"  Size of infinite region descriptor: %d bytes\n",(sizeRo-sizeRoProf)*4);
    fprintf(stderr,"  Number of calls to allocateRegionInf: %d\n",callsOfAllocateRegionInf);
    fprintf(stderr,"  Number of calls to deallocateRegionInf: %d\n",callsOfDeallocateRegionInf);    
    fprintf(stderr,"  Number of calls to alloc: %d\n",callsOfAlloc);
    fprintf(stderr,"  Number of calls to resetRegion: %d\n",callsOfResetRegion);
    fprintf(stderr,"  Number of calls to deallocateRegionsUntil: %d\n",callsOfDeallocateRegionsUntil);

    fprintf(stderr,"\nALLOCATION\n");    
    /*
    fprintf(stderr,"  Alloc. space in infinite regions: %d bytes (%.1fMb)\n", allocNowInf*4, (allocNowInf*4)/Mb);
    fprintf(stderr,"  Alloc. space in finite regions: %d bytes (%.1fMb)\n", allocNowFin*4, (allocNowFin*4)/Mb);
    fprintf(stderr,"  Alloc. space in regions: %d bytes (%.1fMb)\n", (allocNowInf+allocNowFin)*4,((allocNowInf+allocNowFin)*4)/Mb);
    */
    fprintf(stderr,"  Max alloc. space in pages: %d bytes (%.1fMb)\n", maxAllocInf*4,(maxAllocInf*4)/Mb);
    /*
    fprintf(stderr,  "      Space in regions at that time used on profiling: %d bytes (%4.1fMb)\n", maxAllocProfInf*4,
	    (maxAllocProfInf*4)/Mb);
    fprintf(stderr,"  -------------------------------------------------------------------------------\n");
    */
    fprintf(stderr,"    incl. prof. info: %d bytes (%.1fMb)\n", 
	    (maxAllocProfInf+maxAllocInf)*4, ((maxAllocProfInf+maxAllocInf)*4)/Mb);
    fprintf(stderr,"  Infinite regions utilisation (%d/%d): %2.0f%%\n",
	    (maxAllocProfInf+maxAllocInf)*4,
	    (maxNoOfPages*ALLOCATABLE_WORDS_IN_REGION_PAGE*4),
	    ((maxAllocProfInf+maxAllocInf)*4.0)/(maxNoOfPages*ALLOCATABLE_WORDS_IN_REGION_PAGE*4.0)*100.0);
    fprintf(stderr,"  Number of allocated large objects: %d\n", allocatedLobjs);
    fprintf(stderr,"\nSTACK\n");    
    fprintf(stderr,"  Number of calls to allocateRegionFin: %d\n",callsOfAllocateRegionFin);
    fprintf(stderr,"  Number of calls to deallocateRegionFin: %d\n",callsOfDeallocateRegionFin);
    fprintf(stderr,"  Max space for finite regions: %d bytes (%.1fMb)\n", maxAllocFin*4,
	    (maxAllocFin*4)/Mb);
    fprintf(stderr,"  Max space for region descs: %d bytes (%.1fMb)\n", 
	    maxRegionDescUseInf*4, (maxRegionDescUseInf*4)/Mb);
    fprintf(stderr,"  Max size of stack: %d bytes (%.1fMb)\n",
	   ((int)stackBot)-((int)maxStack)-(maxProfStack*4), (((int)stackBot)-((int)maxStack)-(maxProfStack*4))/Mb);
    fprintf(stderr,"    incl. prof. info: %d bytes (%.1fMb)\n", 
	    ((int)stackBot)-((int)maxStack), (((int)stackBot)-((int)maxStack))/Mb);
    fprintf(stderr,"    in profile tick: %d bytes (%.1fMb)\n", 
	    ((int)stackBot)-((int)maxStackP), (((int)stackBot)-((int)maxStackP))/Mb);
    fprintf(stderr,"Number of profile ticks: %d\n", noOfTickInFile);
    /*
    fprintf(stderr,  "      Space used on prof. info. at that time: %d bytes (%.1fMb)\n", 
	    maxRegionDescUseProfInf*4, (maxRegionDescUseProfInf*4)/Mb);
    fprintf(stderr,"  ---------------------------------------------------------------------------------------------\n");
    fprintf(stderr,"  Max space used on infinite region descs on stack: %d bytes (%4.1fMb)\n", 
	    (maxRegionDescUseInf+maxRegionDescUseProfInf)*4,((maxRegionDescUseInf+maxRegionDescUseProfInf)*4)/Mb);
    fprintf(stderr,"      Space used on profiling information at that time: %d bytes (%4.1fMb)\n", 
	    (maxAllocProfFin+maxRegionDescUseProfFin)*4, ((maxAllocProfFin+maxRegionDescUseProfFin)*4)/Mb);
    fprintf(stderr,"  -------------------------------------------------------------------------------------------\n");
    fprintf(stderr,"  Max space used on finite regions on stack: %d bytes (%4.1fMb)\n", 
	    (maxAllocFin+maxAllocProfFin+maxRegionDescUseProfFin)*4,((maxAllocFin+maxAllocProfFin+maxRegionDescUseProfFin)*4)/Mb);
    fprintf(stderr,"    Space used on profiling information at that time: %d bytes (%4.1fMb)\n", 
	    maxProfStack*4, (maxProfStack*4)/Mb);
    fprintf(stderr,"  -------------------------------------------------------------------------------\n");
	    */
    fprintf(stderr,"\n*********End of region statistics*********\n");
  }
  return;
}


/***************************************************************************
 *                Functions for the profiling tool.                        *
 * This module contains functions used when profiling.                     *
 *                                                                         *
 * profileTick(stackTop)                                                   *
 * printProfile()                                                          *
 * outputProfile()                                                         *
 * AlarmHandler()                                                          *
 * callSbrkProfiling() Used to allocate memory to profiling data.          *
 * allocMemProfiling(n) Allocate n bytes to profiling data.                *
 ***************************************************************************/

/*------------------------------------------------------*
 * If an error occurs while profiling, then print the   *
 * error and stop.                                      *
 *------------------------------------------------------*/
char errorStr[255];
void 
profileERROR(char *errorStr) 
{
  fprintf(stderr,"\n***********************ERROR*****************************\n");
  fprintf(stderr,"%s\n", errorStr);
  fprintf(stderr,"\n***********************ERROR*****************************\n");
  exit(-1);
}

/*-----------------------------------------------*
 * This function prints the contents of a finite *
 * region on screen.                             *
 *-----------------------------------------------*/
void 
pp_finite_region (FiniteRegionDesc *frd) 
{
  ObjectDesc *obj;
  obj = (ObjectDesc *) (frd+1);
  fprintf(stderr,"FRDid: %d, next: %d, objectId: %d, objSize: %d\n",
	 frd->regionId, (int)frd, obj->atId, obj->size);
  return;
}

/*--------------------------------------------------*
 * This function prints the contents of an infinite *
 * region on screen.                                *
 *--------------------------------------------------*/
void 
pp_infinite_region (int rAddr) 
{
  ObjectDesc *fObj;
  Klump *crp;
  Ro *rp;
  rp = (Ro *) clearStatusBits(rAddr);
  for(crp=rp->fp; crp != NULL; crp=crp->k.n) 
    {
      fObj = (ObjectDesc *) (((int *)crp)+HEADER_WORDS_IN_REGION_PAGE); /* crp is a Klump. */
      while ( ((int *)fObj < ((int *)crp)+ALLOCATABLE_WORDS_IN_REGION_PAGE+HEADER_WORDS_IN_REGION_PAGE) 
	      && (fObj->atId!=notPP) ) 
	{
	  fprintf(stderr,"ObjAtId %d, Size: %d\n", fObj->atId, fObj->size);
	  fObj=(ObjectDesc *)(((int*)fObj)+((fObj->size)+sizeObjectDesc)); /* Find next object. */
	}
    }
  return;
}

/*---------------------------------------------------*
 * This function prints the contents of all infinite *
 * regions on screen.                                *
 *---------------------------------------------------*/
void 
pp_infinite_regions() 
{
  ObjectDesc *fObj;
  Klump *crp;
  Ro *rp;

  for ( rp = TOP_REGION ; rp ; rp = rp->p ) 
    {
      fprintf(stderr,"Region %d\n", rp->regionId);
      for(crp=rp->fp; crp!=NULL; crp=crp->k.n) 
	{
	  fObj = (ObjectDesc *) (((int *)crp)+HEADER_WORDS_IN_REGION_PAGE); /* crp is a Klump. */
	  while ( ((int *)fObj < ((int *)crp)+ALLOCATABLE_WORDS_IN_REGION_PAGE+HEADER_WORDS_IN_REGION_PAGE) 
		  && (fObj->atId!=notPP) ) 
	    {
	      fprintf(stderr,"ObjAtId %d, Size: %d\n", fObj->atId, fObj->size);
	      fObj=(ObjectDesc *)(((int*)fObj)+((fObj->size)+sizeObjectDesc)); /* Find next object. */
	    }
	}
    }
  return;
}


/*------------------------------------------------------*
 * profiling_on                                         *
 *   Sets alarm for profiling.                          *
 *------------------------------------------------------*/
void 
profiling_on() 
{
  setitimer(profType, &rttimer, &old_rttimer);
  profileON = TRUE;
  if (verboseProfileTick)
    fprintf(stderr,"Profiling turned on...\n");
  return;
}

/*------------------------------------------------------*
 * profiling_off                                        *
 *   Stop alarm for profiling.                          *
 *------------------------------------------------------*/
void 
profiling_off() 
{
  struct itimerval zerotimer;    

  zerotimer.it_value.tv_sec = 0;        /* Time in seconds to first tick. */
  zerotimer.it_value.tv_usec = 0;       /* Time in microseconds to first tick. */
  zerotimer.it_interval.tv_sec = 0;     /* Time in seconds between succeding ticks. */
  zerotimer.it_interval.tv_usec = 0;    /* Time in microseconds between succeding ticks. */
  setitimer(profType, &zerotimer, &old_rttimer);
  profileON = FALSE;
  if (verboseProfileTick)
    fprintf(stderr,"Profiling turned off...\n");
  return;
}

/*------------------------------------------------------*
 * allocMemProfiling                                    *
 *   Takes i bytes from the free-chunk of memory        *
 *   allocated for profiling data.                      *
 *------------------------------------------------------*/
char *
allocMemProfiling_xx(int i) 
{
  char * p;
  char * tempPtr;

  tempPtr = (char *)malloc(i);
  if ( tempPtr == NULL ) 
    {
      perror("malloc error in allocMemProfiling\n");
      exit(-1);
    }

  if ( ((int)tempPtr) % 4 ) 
    {
      perror("allocMemProfiling_xx not aligned\n");
      exit(-1);
    }

  // for debugging: initialize elements
  for ( p = tempPtr ; p < tempPtr+i ; p++ ) 
    {
      *p = 1;  /*dummy*/
    }

  return tempPtr;
}

void 
freeTick(TickList *tick) 
{
  ObjectList *o, *n_o;
  RegionList *r, *n_r;

  debug(printf("[freeTick..."));
  r = tick->fRegion;
  while( r ) 
    {
      n_r = r->nRegion;      
      o = r->fObj;
      while( o ) 
	{
	  n_o = o->nObj;
	  free(o);
	  o = n_o;
	}
      free(r);
      r = n_r;
    }
  free(tick);
}

/*------------------------------------------------------*
 * AlarmHandler:                                        *
 *     Handler function used to profile regions.        *
 *------------------------------------------------------*/
void 
AlarmHandler() 
{
  timeToProfile = 1;
  signal(signalType, AlarmHandler);   // setup signal again
}

/*-------------------------------------------------------------------*
 * ProfileTick: Update the tick list by traversing all regions.      *
 *-------------------------------------------------------------------*/
void 
profileTick(int *stackTop) 
{
  int i;
  TickList *newTick;
  FiniteRegionDesc *frd;
  ObjectDesc *fObj;
  ObjectList *newObj, *tempObj;
  RegionList *newRegion;
  Ro *rd;                        /* Used as pointer to infinite region. */
  Klump *crp;                    /* Pointer to a region page. */

  int finiteRegionDescUse;       /* Words used on finite region descriptors. */
  int finiteObjectDescUse;       /* Words used on object descriptors in finite regions. */
  int finiteObjectUse;           /* Words used on objects in finite regions. */
  int infiniteObjectUse;         /* Words used on objects in infinite regions. */
  int infiniteObjectDescUse;     /* Words used on object descriptors in infinite regions. */
  int infiniteRegionWaste;       /* Words not used in region pages. */
  int regionDescUseProf;         /* Words used on extra fields in infinite region desc. when profiling. */

  /*  checkProfTab("profileTick.enter"); */

  doing_prof = 1; /* Mutex on profilig */ 
  debug(printf("Entering profileTick\n"));

  if ( profType == noTimer ) 
    {
      tempAntal ++;
      if ( tempAntal < profNo )
	return;
      tempAntal = 0;
    } 
  else
    {
      timeToProfile = 0; // We use timer so no profiling before next tick
    }
  
  if ( verboseProfileTick )
    {
      fprintf(stderr,"profileTick -- ENTER\n");
    }

  finiteRegionDescUse = 0;
  finiteObjectDescUse = 0;
  finiteObjectUse = 0;
  infiniteObjectUse = 0;
  infiniteObjectDescUse = 0;
  infiniteRegionWaste = 0;
  regionDescUseProf = 0;

  /* Allocate new tick. */
  newTick = (TickList *)allocMemProfiling_xx(sizeof(TickList));

  newTick->stackUse = ((int *)stackBot)-((int *)stackTop);
  maxStackP = (int *) min((int)maxStackP, (int)stackTop);

  /*  printf("Stackuse at entry %d, stackbot: %x, stackTop: %x\n", newTick->stackUse, stackBot, stackTop); */

  if ( newTick->stackUse < 0 ) 
    {
      sprintf(errorStr, "ERROR1 - PROFILE_TICK -- stackUse in profileTick less than zero %d (bot %x, top %x)\n",
	      newTick->stackUse, stackBot, stackTop);
      profileERROR(errorStr);
    }

  newTick->regionDescUse = 0;
  cpuTimeAcc += (unsigned int)(((unsigned int)clock())-lastCpuTime);
  newTick->time = cpuTimeAcc;
  if ( tellTime == 1 ) 
    {
      fprintf(stderr,"The time is: %d\n", cpuTimeAcc);
      tellTime = 0;
    }
  newTick->nTick   = NULL; /* to be erased 2001-05-13, Niels */
  newTick->fRegion = NULL; /* to be erased 2001-05-13, Niels */
  if (firstTick == NULL)   /* to be erased 2001-05-13, Niels */
    firstTick = newTick;   /* to be erased 2001-05-13, Niels */
  else                         /* to be erased 2001-05-13, Niels */
    lastTick->nTick = newTick; /* to be erased 2001-05-13, Niels */
  lastTick = newTick;          /* to be erased 2001-05-13, Niels */

  /* Initialize hash table for regions. */
  initializeRegionListTable();

  /********************************/
  /* Traverse finite region list. */
  /********************************/

  for ( frd = topFiniteRegion ; frd ; frd = frd->p ) 
    {
      finiteRegionDescUse += sizeFiniteRegionDesc;
      finiteObjectDescUse += sizeObjectDesc;
      newTick->stackUse -= sizeFiniteRegionDesc;
      newTick->stackUse -= sizeObjectDesc;
      if (newTick->stackUse < 0) 
	{
	  sprintf(errorStr, "ERROR2 - PROFILE_TICK -- stackUse in profileTick less than zero %d\n",
		  newTick->stackUse);
	  profileERROR(errorStr);
	}
      fObj = (ObjectDesc *) (frd+1);

      /*    printf("FiniteRegionInfo: regionId: %d, pPoint: %d, size: %d, stackuse: %d, stacksize: %d\n",
	    frd->regionId, fObj->atId, fObj->size, newTick->stackUse, 
	    ((int *)stackBot)-((int *)stackTop)); 2001-05-11, Niels */
    
      if ( fObj->size >= ALLOCATABLE_WORDS_IN_REGION_PAGE ) 
	{
	  sprintf(errorStr, "ERROR - PROFILE_TICK -- Size quite big, pp: %d with  \
              size %d, fObj-1: %d, fObj %d in finite region %d\n", 
		  fObj->atId, fObj->size, *(((int*)fObj)-1), (int)fObj, frd->regionId);
	  profileERROR(errorStr);
	}
    
      newTick->stackUse -= fObj->size;

      finiteObjectUse += fObj->size;
      if ( newTick->stackUse < 0 ) 
	{
	  fprintf(stderr,"ERROR3 - PROFILE_TICK -- stackUse in profileTick less than \
             zero %d, after object with size %d and pp %d, stackBot: %x, stackTop: %x\n",
		  newTick->stackUse, fObj->size, fObj->atId, stackBot, stackTop);
	  profileERROR(errorStr);
	}

      if ( lookupRegionListTable(frd->regionId) == NULL ) 
	{
	  newRegion = (RegionList *)allocMemProfiling_xx(sizeof(RegionList));
	  newRegion->regionId = frd->regionId;
	  newRegion->used = fObj->size;                   
	  newRegion->waste = 0;                  
	  newRegion->noObj = 1;
	  newRegion->infinite = 0;
	  newRegion->nRegion = newTick->fRegion;
	  newTick->fRegion = newRegion;;
	  newObj = (ObjectList *)allocMemProfiling_xx(sizeof(ObjectList));
	  newRegion->fObj = newObj;
	  newObj->atId = fObj->atId;
	  newObj->size = fObj->size;
	  newObj->nObj = NULL;
	  insertRegionListTable(frd->regionId, newRegion);
	} 
      else 
	{
	  newRegion = lookupRegionListTable(frd->regionId);
	  if ( newRegion->infinite ) 
	    { 
	      // for check only
	      sprintf(errorStr, "ERROR - PROFILE_TICK -- finite region %3d is allocated as infinite. \n",
		      newRegion->regionId);
	      profileERROR(errorStr);
	    }
	  newRegion->used += fObj->size;

	  /* See if object is already allocated. */
	  newObj = NULL;
	  for ( tempObj = newRegion->fObj ; tempObj && newObj == NULL ; tempObj = tempObj->nObj )
	    {
	      if (tempObj->atId == fObj->atId)
		newObj = tempObj;
	    }

	  if ( newObj == NULL ) 
	    {	      
	      // Allocate new object
	      newObj = (ObjectList *)allocMemProfiling_xx(sizeof(ObjectList));
	      newObj->atId = fObj->atId;
	      newObj->size = fObj->size;
	      newObj->nObj = newRegion->fObj;
	      newRegion->fObj = newObj;
	      newRegion->noObj++;
	    } 
	  else 
	    {
	      newObj->size += fObj->size;
	    }
	}
    }

  /**********************************/
  /* Traverse infinite region list. */
  /**********************************/

  for ( rd = TOP_REGION ; rd ; rd = rd->p ) 
    {
      
      /* printf("ERROR4 -PROFILE_TICK -- stackUse in profileTick less than zero %d, regionId: %d\n",
	 newTick->stackUse, rd->regionId); */

      newTick->stackUse -= sizeRo;             // size of infinite region desc
      if (newTick->stackUse < 0) 
	{
	  sprintf(errorStr, "ERROR4 -PROFILE_TICK -- stackUse in profileTick less than zero %d\n",
		  newTick->stackUse);
	  profileERROR(errorStr);
	}
      newTick->regionDescUse += (sizeRo-sizeRoProf); // size of infinite region desc without prof
      regionDescUseProf += sizeRoProf;               // size of profiling fields in inf reg desc
      if ( lookupRegionListTable(rd->regionId) == NULL ) 
	{
	  newRegion = (RegionList *)allocMemProfiling_xx(sizeof(RegionList));
	  newRegion->regionId = rd->regionId;
	  newRegion->used = 0;
	  newRegion->waste = 0;                  
	  newRegion->noObj = 0;
	  newRegion->infinite = 1;
	  newRegion->nRegion = newTick->fRegion;
	  newTick->fRegion = newRegion;
	  newRegion->fObj = NULL;
	  insertRegionListTable(rd->regionId, newRegion);
	} 
      else 
	{
	  newRegion = lookupRegionListTable(rd->regionId);
	  if ( newRegion->infinite != 1 ) 
	    { 
	      // For check only
	      sprintf(errorStr, "ERROR - PROFILE_TICK -- infinite region %3d is allocated as finite. \n",
		      newRegion->regionId);
	      profileERROR(errorStr);
	    }
	}

      // Initialize hash table for objects
      initializeObjectListTable();
      
      for ( newObj = newRegion->fObj ; newObj ; newObj = newObj->nObj )
	{
	  insertObjectListTable(newObj->atId, newObj);
	}

      /* Traverse objects in current region, except the last region page, 
       * which is traversed independently; crp always points at the 
       * beginning of a regionpage(=nPtr|dummy|data). */

      for( crp = rd->fp ; crp->k.n ; crp = crp->k.n ) 
	{
	  fObj = (ObjectDesc *) (((int *)crp)+HEADER_WORDS_IN_REGION_PAGE); // crp is a Klump
	  // notPP = 0 means no object allocated

	  while ( ((int *)fObj < ((int *)crp)+ALLOCATABLE_WORDS_IN_REGION_PAGE+HEADER_WORDS_IN_REGION_PAGE) 
		  && (fObj->atId!=notPP) ) 
	    {
	      if ( lookupObjectListTable(fObj->atId) == NULL ) 
		{
		  // Allocate new object
		  newObj = (ObjectList *)allocMemProfiling_xx(sizeof(ObjectList));
		  newObj->atId = fObj->atId;
		  newObj->size = fObj->size;
		  newObj->nObj = newRegion->fObj;
		  newRegion->fObj = newObj;
		  newRegion->used += fObj->size;
		  newRegion->noObj++;
		  insertObjectListTable(fObj->atId, newObj);
		} 
	      else 
		{
		  newObj = lookupObjectListTable(fObj->atId);
		  newObj->size += fObj->size;
		  newRegion->used += fObj->size;
		}
	      infiniteObjectUse += fObj->size;
	      infiniteObjectDescUse += sizeObjectDesc;
	      fObj=(ObjectDesc *)(((int*)fObj)+((fObj->size)+sizeObjectDesc)); // Find next object
	    }
	  newRegion->waste += (int)((((int *)crp)+ALLOCATABLE_WORDS_IN_REGION_PAGE+HEADER_WORDS_IN_REGION_PAGE)-((int *)fObj));
	  infiniteRegionWaste += (int)((((int *)crp)+ALLOCATABLE_WORDS_IN_REGION_PAGE+HEADER_WORDS_IN_REGION_PAGE)-((int *)fObj));
	  /* No more objects in current region page. */
	}
      
      /* Now we need to traverse the last region page, now pointed 
       * to by crp (crp is a Klump) */
      fObj = (ObjectDesc *) (((int *)crp)+HEADER_WORDS_IN_REGION_PAGE);

      while ( (int *)fObj < rd->a ) 
	{
	  if ( lookupObjectListTable(fObj->atId) == NULL ) 
	    {
	      // Allocate new object
	      newObj = (ObjectList *)allocMemProfiling_xx(sizeof(ObjectList));
	      newObj->atId = fObj->atId;
	      newObj->size = fObj->size;
	      newObj->nObj = newRegion->fObj;
	      newRegion->fObj = newObj;
	      newRegion->used += fObj->size;
	      newRegion->noObj++;
	      insertObjectListTable(fObj->atId, newObj);
	    } 
	  else 
	    {
	      newObj = lookupObjectListTable(fObj->atId);
	      newObj->size += fObj->size;
	      newRegion->used += fObj->size;
	    }
	  infiniteObjectUse += fObj->size;
	  infiniteObjectDescUse += sizeObjectDesc;
	  fObj=(ObjectDesc *)(((int*)fObj)+((fObj->size)+sizeObjectDesc)); /* Find next object. */
	}
      newRegion->waste += (int)((((int *)crp)+ALLOCATABLE_WORDS_IN_REGION_PAGE+HEADER_WORDS_IN_REGION_PAGE)-((int *)fObj));
      infiniteRegionWaste += (int)((((int *)crp)+ALLOCATABLE_WORDS_IN_REGION_PAGE+HEADER_WORDS_IN_REGION_PAGE)-((int *)fObj));
      
      /* No more objects in the last region page. */
    }
  
  lastCpuTime = (unsigned int)clock();
  
  if ( verboseProfileTick ) 
    {      
      fprintf(stderr,"Memory use on the stack at time %d (in bytes)\n", newTick->time);
      fprintf(stderr,"      Infinite region descriptors..........: %10d\n", newTick->regionDescUse*4);
      fprintf(stderr,"      Objects allocated in finite regions..: %10d\n", finiteObjectUse*4);
      fprintf(stderr,"      Other data on the stack..............: %10d\n", newTick->stackUse*4);
      fprintf(stderr,"    Total allocated data by program........: %10d\n\n",
	      (newTick->regionDescUse+finiteObjectUse+newTick->stackUse)*4);
      fprintf(stderr,"      Finite region descriptors............: %10d\n", finiteRegionDescUse*4);
      fprintf(stderr,"      Prof. fields in infinite region desc.: %10d\n", regionDescUseProf*4);
      fprintf(stderr,"      Object descriptors in finite regions.: %10d\n", finiteObjectDescUse*4);
      fprintf(stderr,"    Total allocated data by profiler.......: %10d\n", (finiteRegionDescUse+finiteObjectDescUse+regionDescUseProf)*4);
      fprintf(stderr,"  Total stack use..........................: %10d\n",
	      (newTick->regionDescUse+finiteObjectUse+newTick->stackUse+finiteRegionDescUse+finiteObjectDescUse+regionDescUseProf)*4);
      
      if (((newTick->regionDescUse+finiteObjectUse+newTick->stackUse+
	    finiteRegionDescUse+finiteObjectDescUse+regionDescUseProf)*4) != (stackBot-stackTop)*4)
	fprintf(stderr,"ERROR -- stacksize error in ProfileTick\n");
      
      fprintf(stderr,"Memory use in regions at time %d (in bytes)\n", newTick->time);
      fprintf(stderr,"    Objects allocated in infinite regions..: %10d\n", infiniteObjectUse);
      fprintf(stderr,"    Object descriptors in infinite regions.: %10d\n", infiniteObjectDescUse);
      fprintf(stderr,"    Total waste in region pages............: %10d\n", infiniteRegionWaste);
      fprintf(stderr,"  Total memory allocated to region pages...: %10d\n", 
	      (infiniteObjectUse+infiniteObjectDescUse+infiniteRegionWaste)*4);
      if ( ((infiniteObjectUse+infiniteObjectDescUse+infiniteRegionWaste)*4) % ALLOCATABLE_WORDS_IN_REGION_PAGE != 0 )
	fprintf(stderr,"ERROR -- region page size error in profileTick\n");
      
      fprintf(stderr,"profileTick -- LEAVE\n");
    }
  
  outputProfileTick(newTick);
  freeTick(newTick);
  
  if ( profileON && profType != noTimer ) 
    {
      profiling_on();
    }

  doing_prof = 0;

  /*  checkProfTab("profileTick.exit"); */
  
  if (raised_exn_interupt_prof) 
    raise_exn((int)&exn_INTERRUPT);
  if (raised_exn_overflow_prof)
    raise_exn((int)&exn_OVERFLOW);  
}

/*-------------------------------------------------------------------*
 * PrintProfile: Print all collected data on screen.                 *
 *-------------------------------------------------------------------*/
void 
printProfile(void) 
{
  TickList *newTick;
  ObjectList *newObj;
  RegionList *newRegion;

  for ( newTick = firstTick ; newTick ; newTick = newTick->nTick ) 
    {
      fprintf(stderr,"Starting new tick.\n");
      for ( newRegion = newTick->fRegion ; newRegion ; newRegion = newRegion->nRegion ) 
	{
	  if ( newRegion->infinite ) 
	    {
	      fprintf(stderr,"  Infinite region: %3d, used: %3d, waste: %3d, noObj: %3d, Infinite: %3d.\n",
		      newRegion->regionId, newRegion->used, newRegion->waste,
		      newRegion->noObj,newRegion->infinite);
	    }
	  else
	    {
	      fprintf(stderr,"  Finite region: %3d, used: %3d, waste: %3d, noObj: %3d, Infinite: %3d.\n",
		      newRegion->regionId, newRegion->used, newRegion->waste,
		      newRegion->noObj,newRegion->infinite);
	    }
	  for ( newObj = newRegion->fObj ; newObj ; newObj = newObj->nObj ) 
	    {
	      fprintf(stderr,"    Starting new object with allocation point %3d, and size %3d.\n",
		      newObj->atId, newObj->size);
	    }
	}
    }
  return;
}

/*----------------------------------------------------------------*
 * OutputProfile:                                                 *
 * Output word data file with all collected data.                 *
 * Layout of file is as follows:                                  *
 *  maxRegion                                                     *
 *  noOfTicks,                                                    *
 *      noOfRegions, stackUse, regionDescUse, cpuTime             *
 *        regionId, used, waste, noOfObj, infinite                *
 *          allocationPoint, size                                 *
 *          |                                                     *
 *	    allocationPoint, size                                 *
 *        |                                                       *
 *        regionId, used, waste, noOfObj, infinite                *
 *          allocationPoint, size                                 *
 *          |                                                     *
 *	    allocationPoint, size                                 *
 *      |                                                         *
 *      noOfRegions, stackUse, regionDescUse, cpuTime             *
 *        regionId, used, waste, noOfObj, infinite                *
 *          allocationPoint, size                                 *
 *          |                                                     *
 *	    allocationPoint, size                                 *
 *        |                                                       *
 *        regionId, used, waste, noOfObj, infinite                *
 *          allocationPoint, size                                 *
 *          |                                                     *
 *	    allocationPoint, size                                 *
 *  |                                                             *
 * Here we put the profiling table profTab:                       *
 *  sizeProfTab,                                                  *
 *    regionId, MaxAlloc                                          *
 *    |                                                           *
 *    regionId, MaxAlloc                                          *
 *----------------------------------------------------------------*/

void 
outputProfilePre(void) 
{
  debug(printf("[outputProfilePre..."));

  if ( exportProfileDatafile ) 
    {
      if ((logFile_xx = fopen((char *) &logName_xx, "w")) == NULL) {
	fprintf(stderr,"Cannot open logfile.\n");
	exit(-1);
      }
    }

  putw(42424242, logFile_xx); /* dummy maxAlloc, updated in outputProfilePost */
  putw(42424242, logFile_xx); /* dummy noOfTicks, updated in outputProfilePost */

  noOfTickInFile = 0; /* Initialize counter tick-counter */

  debug(printf("]"));

  return;
}

void 
outputProfileTick(TickList *tick) 
{
  int noOfRegions;
  ObjectList *newObj;
  RegionList *newRegion;

  debug(printf("[outputProfileTick..."));

  if (exportProfileDatafile) 
    {
      noOfTickInFile++; /* Increment no of tick-counter */
      noOfRegions = 0;
      for (newRegion = tick->fRegion ; newRegion ; newRegion = newRegion->nRegion )
	noOfRegions++;

      putw(noOfRegions, logFile_xx);
      putw(tick->stackUse, logFile_xx);
      putw(tick->regionDescUse, logFile_xx);
      putw(tick->time, logFile_xx);

      for (newRegion = tick->fRegion ; newRegion ; newRegion = newRegion->nRegion ) 
	{
	  putw(newRegion->regionId, logFile_xx);
	  putw(newRegion->used, logFile_xx);
	  putw(newRegion->waste, logFile_xx);
	  putw(newRegion->noObj, logFile_xx);
	  putw(newRegion->infinite, logFile_xx);

	  for ( newObj = newRegion->fObj ; newObj ; newObj = newObj->nObj ) 
	    {
	      putw(newObj->atId, logFile_xx);
	      putw(newObj->size, logFile_xx);
	    }
	}
    }
  debug(printf("]"));
  return;
}

void 
outputProfilePost(void) 
{
  int i;
  ProfTabList* p;

  debug(printf("[outputProfilePost..."));

  /* Output profTab to log file. */
  putw(profTabSize(), logFile_xx);
  for ( i = 0 ; i < PROF_HASH_TABLE_SIZE ; i++ ) 
    for (p=profHashTab[i]; p != NULL; p=p->next) 
      {
	putw(p->regionId, logFile_xx);
	putw(p->maxAlloc, logFile_xx);
      }

  fseek(logFile_xx, 0, SEEK_SET);    // seek to the beginning of file 
  putw(maxAlloc, logFile_xx);        // overwrite first two words
  putw(noOfTickInFile, logFile_xx);
  fclose(logFile_xx);
  debug(printf("]")); 
  return;
}

#else /*PROFILING is not defined */

void 
queueMark(StringDesc *str)
{
  return;
}

#endif /*PROFILING*/
