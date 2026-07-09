**FREE
// =====================================================================
//  OP001UI2 - Pick & Pack Casing (clean-slate rewrite)   SLICE 1 + 2
//  ---------------------------------------------------------------------
//  Slice 1 : packaging + weight core (per-rug lookups).
//  Slice 2 : the driver + packing engine --
//     - Main       : cursor over OP001WF in pick order; order-break loop
//     - PackOrder  : one order's rugs -> cartons (three modes below)
//     - PackRug    : dispatch a rug by packaging kind
//     - CloseCarton: finalize + write the carton, reset accumulators
//
//  THREE PACKING MODES (from the domain Q&A):
//     R roll        -> rolled & wrapped, no carton (majority of items)
//     B assigned box-> ceil(xqty / casepack) boxes of the assigned box
//     F best-fit    -> accumulate rugs by cube; fill until the next group
//                      won't fit (cube or weight), then close; carton = the
//                      smallest direct carton (RMCUSDF list 2) that fits.
//
//  Driving file: ASTEST2/OP001WF (physical; OP001L8 is its keyed logical).
//     One record per rug, MANY per order. Carries EACUBE (cubes each);
//     weight from INVMST; casepack from BCMST1 (BCSPCD).
//  Files via libl: RMBOXXF/RMBOXXF2/BCMST1->MAPDBFA; RMCUSDF->LABDBFA; INVMST->INVLIB
//
//  INTEGRATION STUBS (carry over from C12, not rebuilt in this slice):
//     AllocateCaseNumber  -> the locked data-area numbering (verbatim from C12)
//     WriteDetail/WriteCarton -> OP002WF / OP003WF record writes (exact field map TBD)
//     ResolveShipCustomer -> name -> numeric savcu# (SH241F); + retailer procs
//  ROLL rule (confirmed): roll-by-itself when order total units = 1, OR the
//     rug's cube >= MAX_CARTON_CUBE. Otherwise consolidate into the carton.
//     No weight cap -- cube (4800) is the only carton limit.
//  ACCEPTED FOR NOW: style/size read from INVMST (OP001WF SORTST5 is corrupt;
//     user will fix the OP001WF build separately -- several program changes).
// =====================================================================
ctl-opt option(*srcstmt:*nodebugio) dftactgrp(*no) actgrp(*new) main(Main);

   dcl-f sh241f keyed;
   dcl-f op004pf keyed;
   dcl-f calall1 keyed;

dcl-ds packaging_t qualified template;
   kind     char(1);       // 'R' roll | 'B' assigned box | 'F' best-fit
   boxId    char(5);
   cube     packed(7:0);
   tare     packed(7:3);
   groupQty packed(3:0);  // atomic group size from BCMST2P B2NM06; default 1
end-ds;

// ---- one rug (driving row), trimmed to what packing needs ----
dcl-ds rug_t qualified template;
   custNo packed(7:0);   // resolved ship customer (savcu#)
   style  char(5);
   size   char(7);
   colr2  char(2);       // CLR (INVMST key)
   colr9  char(9);       // CLR left-justified (RMBOXXF/BCMST1 key)
   dept   char(3);
   lot    char(6);
   qty    packed(7:0);
   eaCube packed(7:0);   // OP001WF.EACUBE (per-unit cube)
   ordLines packed(5:0); // # of rug lines on this rug's order (window count)
   ordUnits packed(7:0); // total units on this rug's order (window sum of xqty)
end-ds;

// ---- module-level carton accumulator (best-fit mode) ----
dcl-ds carton qualified;
   cube    packed(9:0);
   weight  packed(9:2);
   units   packed(7:0);
   isOpen  ind;
end-ds;

dcl-c MAX_CARTON_CUBE 4800;   // confirmed 4800 (also held in the QGPL/MAXCUBE data area)
dcl-c MAX_RUGS 9999;          // max rug lines buffered per order

// =====================================================================
dcl-proc Main;
   dcl-ds r likeds(rug_t);
   dcl-s  brkKey char(41);      // customer+sort1+sort2+str#+po# (carton break)
   dcl-s  curKey char(41);

   // pick order matches the current program's read order
   // ordLines / ordUnits are the "running order total" for this rug's order:
   //   window counts over the SAME key that drives the carton break below.
   //   Every fetched row therefore knows how many rug lines / units share its
   //   order -- which is what the single-item-roll decision needs (a ROLL rug
   //   can only "roll by itself" when it is genuinely the whole order).
   exec sql declare pick cursor for
      select cusomer, sort1, sort2, str#, po#, sortsq,
             dpno, lot#, clr, xqty, eacube, sortst5, sortsz,
             count(*)  over (partition by cusomer,sort1,sort2,str#,po#),
             sum(xqty) over (partition by cusomer,sort1,sort2,str#,po#)
        from op001wf
       order by cusomer, sort1, sort2, str#, po#, sortsq;
   exec sql open pick;

   curKey = *blanks;
   dow fetchRug(r : brkKey);
      if carton.isOpen and brkKey <> curKey;   // carton break -> flush
         CloseCarton();
      endif;
      curKey = brkKey;
      PackRug(r);
   enddo;
   if carton.isOpen;
      CloseCarton();             // flush the last carton
   endif;

   exec sql close pick;
   return;
end-proc;
// =====================================================================
// ---- fetch next rug, map row -> rug_t, build the break key ----
dcl-proc fetchRug;
   dcl-pi *n ind;
      r      likeds(rug_t);
      brkKey char(41);
   end-pi;
   dcl-s cusomer char(10);
   dcl-s sort1 char(10);
   dcl-s sort2 char(10);
   dcl-s str# char(6);
   dcl-s po# char(8);
   dcl-s sortsq char(10);
   dcl-s dpno char(3);
   dcl-s lot# char(6);
   dcl-s clr char(2);
   dcl-s xqty packed(7:0);
   dcl-s eacube packed(7:0);
   dcl-s st5 char(10);
   dcl-s ssz char(10);
   dcl-s ordlines packed(5:0);
   dcl-s ordunits packed(7:0);

   exec sql fetch pick into :cusomer,:sort1,:sort2,:str#,:po#,:sortsq,
                            :dpno,:lot#,:clr,:xqty,:eacube,:st5,:ssz,
                            :ordlines,:ordunits;
   if sqlcode <> 0;
      return *off;               // end of data (or error -> stop)
   endif;

   clear r;
   r.custNo = ResolveShipCustomer(cusomer);   // name -> numeric savcu#
   Exec Sql
    Select trim(style)
      into :r.style
    from invmst
    Where deptno = :dpno
    And lotno = :lot#
    And color = :clr
    limit 1;
   r.size   = %trim(ssz);
   r.colr2  = clr;
   r.colr9  = clr;                            // char(2) left-justified into char(9)
   r.dept   = dpno;
   r.lot    = lot#;
   r.qty    = xqty;
   r.eaCube = eacube;
   r.ordLines = ordlines;
   r.ordUnits = ordunits;
   brkKey   = cusomer + sort1 + sort2 + str# + po#;
   return *on;
end-proc;

// =====================================================================
//  PackRug - route one rug by its packaging kind.
// =====================================================================
dcl-proc PackRug;
   dcl-pi *n;
      r likeds(rug_t) const;
   end-pi;
   dcl-ds pkg likeds(packaging_t);
   dcl-s  rugWt     packed(9:2);
   dcl-s  casepk    packed(5:0);
   dcl-s  boxes     packed(7:0);
   dcl-s  i         packed(7:0);

   pkg    = DeterminePackaging(r.custNo : r.style : r.size : r.colr9);
   rugWt  = RugWeight(r.dept : r.lot : r.colr2);

   select;
   // ---- ROLL: rolled & wrapped, no carton -- BUT only when it's alone. ----
   // Two roll triggers (confirmed by business):
   //   1. the WHOLE order is a single unit (ordUnits = 1), or
   //   2. the rug is too big for the largest carton (eaCube >= MAX_CARTON_CUBE).
   // Any other ROLL-flagged rug on a multi-unit order is NOT cased by itself;
   // it is consolidated into the order's carton like any other rug.
   when pkg.kind = 'R';
      if r.ordUnits = 1 or r.eaCube >= MAX_CARTON_CUBE;
         for i = 1 to r.qty;
            WriteRoll(r : rugWt);
         endfor;
      else;
         PlaceInCarton(r : rugWt : 1);   // groupQty 1: each rug placed on its own
      endif;

   // ---- ASSIGNED BOX: ceil(qty / casepack) boxes of the assigned box ----
   when pkg.kind = 'B';
      casepk = GetCasepack(r.custNo : r.style : r.size : r.colr9);
      boxes  = %div(r.qty + casepk - 1 : casepk);   // ceil
      for i = 1 to boxes;
         WriteCarton(pkg.boxId : pkg.tare
                     : casepk * r.eaCube
                     : (casepk * rugWt) + pkg.tare
                     : casepk);
      endfor;

   // ---- BEST-FIT: accumulate into the open carton in atomic groups ----
   // pkg.groupQty comes from BCMST2P B2NM06 (Walmart P&P grouping; 1 for all others).
   // Fill while the carton stays <= MAX_CARTON_CUBE (see PlaceInCarton).
   // The last iteration uses %min() so a short tail (qty not divisible by groupQty)
   // is handled cleanly -- same behaviour as C12's spinqty decrement logic (short tail).
   when pkg.kind = 'F';
      PlaceInCarton(r : rugWt : pkg.groupQty);
   endsl;
   return;
end-proc;

// =====================================================================
//  PlaceInCarton - accumulate a rug's units into the open best-fit carton
//  in atomic groups of groupQty, closing the carton before a group would
//  overflow the cube (or weight) cap.  Shared by best-fit ('F') and by the
//  multi-rug ROLL path (which consolidates rather than rolling by itself).
//  groupQty comes from BCMST2P B2NM06 (Walmart P&P grouping; 1 otherwise).
// =====================================================================
dcl-proc PlaceInCarton;
   dcl-pi *n;
      r        likeds(rug_t) const;
      rugWt    packed(9:2)   const;
      groupQty packed(3:0)   const;
   end-pi;
   dcl-s remaining packed(7:0);
   dcl-s grpSz     packed(3:0);

   remaining = r.qty;
   dow remaining > 0;
      grpSz = %min(groupQty : remaining);
      // fill WHILE <= MAX_CARTON_CUBE; close before a group tips it over
      // (over 4800 is already too late). Cube is the only cap -- no weight cap.
      if carton.isOpen
         and ( carton.cube + (grpSz * r.eaCube) > MAX_CARTON_CUBE );
         CloseCarton();
      endif;
      carton.isOpen  = *on;
      carton.cube   += grpSz * r.eaCube;
      carton.weight += grpSz * rugWt;
      carton.units  += grpSz;
      WriteDetail(r : grpSz);   // one detail write covers the whole group
      remaining -= grpSz;
   enddo;
   return;
end-proc;

// =====================================================================
//  CloseCarton - pick the best-fit carton for the accumulated cube,
//  add its tare, write the carton record, reset the accumulator.
// =====================================================================
dcl-proc CloseCarton;
   dcl-ds pkg likeds(packaging_t);
   if not carton.isOpen;
      return;
   endif;
   pkg = SelectCarton(carton.cube);       // smallest direct carton that fits
   if pkg.kind = 'R';                      // nothing fits -> it rolls (big cube)
      // (rare; treat as roll of the accumulated units - refine in a later slice)
   else;
      WriteCarton(pkg.boxId : pkg.tare
                  : carton.cube
                  : carton.weight + pkg.tare
                  : carton.units);
   endif;
   clear carton;
   return;
end-proc;

// =====================================================================
//  ---- Slice-1 packaging/weight core (unchanged) ----
// =====================================================================
dcl-proc DeterminePackaging export;
   dcl-pi *n likeds(packaging_t);
      custNo packed(7:0) const;
      style  char(5)     const;
      size   char(7)     const;
      color  char(9)     const;   // RMBOXXF.BXCOLR char(9); char(2) CLR left-justified
   end-pi;
   dcl-ds pkg likeds(packaging_t);
   dcl-s  assignedBox char(5) inz;

   clear pkg;
   exec sql
      select bxinum into :assignedBox
        from rmboxxf
       where bxcust = :custNo and bxstyl = :style
         and bxsize = :size   and bxcolr = :color
       fetch first 1 row only;

   if %trim(assignedBox) = 'ROLL';
      pkg.kind     = 'R';
      pkg.groupQty = 1;
      return pkg;
   endif;
   if assignedBox <> *blanks;
      pkg.kind  = 'B';
      pkg.boxId = assignedBox;
      GetBox(assignedBox : pkg.cube : pkg.tare);
      pkg.groupQty = 1;    // 'B' mode uses casepack from BCMST1, not groupQty
      return pkg;
   endif;



   pkg.kind = 'F';
   return pkg;
end-proc;
// =====================================================================
dcl-proc GetBox export;
   dcl-pi *n;
      boxId char(5)     const;
      cube  packed(7:0);
      tare  packed(7:3);
   end-pi;
   exec sql
      select bxidcuin, bxweight into :cube, :tare
        from rmboxxf2
       where bxinum = :boxId;
   if sqlcode <> 0;
      cube = 0;
      tare = 0;
   endif;
end-proc;
// =====================================================================
dcl-proc SelectCarton export;
   dcl-pi *n likeds(packaging_t);
      neededCube packed(7:0) const;
   end-pi;
   dcl-ds pkg likeds(packaging_t);
   clear pkg;
   exec sql
      select d.rcinum, d.rcmaxc, coalesce(b.bxweight, 0)
        into :pkg.boxId, :pkg.cube, :pkg.tare
        from rmcusdf d
        left join rmboxxf2 b on b.bxinum = d.rcinum
       where d.rccust = 2 and d.rcmaxc >= :neededCube
       order by d.rcmaxc
       fetch first 1 row only;
   if sqlcode = 0;
      pkg.kind = 'B';
   else;
      pkg.kind = 'R';            // too big for any carton -> roll
   endif;
   return pkg;
end-proc;
// =====================================================================
dcl-proc GetCasepack export;
   dcl-pi *n packed(5:0);
      custNo packed(7:0) const;
      style  char(5)     const;
      size   char(7)     const;
      color  char(9)     const;
   end-pi;
   dcl-s cp packed(5:0);
   exec sql
      select dec(bcspcd) into :cp
        from bcmst1
       where bccus# = :custNo and bcstyl = :style
         and bcisiz = :size   and bcicol = :color
       fetch first 1 row only;
   if sqlcode <> 0 or cp < 1;
      cp = 1;
   endif;
   return cp;
end-proc;
// =====================================================================
dcl-proc RugWeight export;
   dcl-pi *n packed(9:2);
      dept  char(3) const;
      lot   char(6) const;
      color char(2) const;      // INVMST.COLOR is char(2)
   end-pi;
   dcl-s wt packed(4:0);
   exec sql
      select weight into :wt
        from invmst
       where deptno = :dept and lotno = :lot and color = :color
       fetch first 1 row only;
   if sqlcode <> 0;
      wt = 0;
   endif;
   return wt * 0.01;
end-proc;

// =====================================================================
//  ---- INTEGRATION STUBS (fill in next slices; carry C12 logic) ----
// =====================================================================
dcl-proc ResolveShipCustomer;
   dcl-pi *n packed(7:0);
      cusomer char(10) const;
   end-pi;

     chain (cusomer) sh241f;
       If not%found(sh241f);
         Exec Sql
          Select custnum
            into :shccde
          From maputil.mapcustatr
          Where processnam = 'OP001UI'
          And functioncd = :cusomer;
       Endif;

   return shccde;

end-proc;
// =====================================================================
dcl-proc AllocateCaseNumber;
   dcl-s invN packed(6:0) dtaara('NXTPT#');
   dcl-s invI packed(6:0) dtaara('INVOIN');
   dcl-s cas char(6);
   dcl-s i int(10);

   chain (cusomer) op004pf;
     If %found(op004pf);
       for i = 1 to 5000;
         Select;
           When opnxt# = 'NXTPT#';
              in *lock invN;
                If invN = 999999;
                  invN = 2002;
                Else;
                  invN += 1;
                Endif;
              out invN;
              unlock invN;
              evalr cas = %trimr(invN:'Z');
           When opnxt# = 'INVOIN';
              in *lock invI;
              invI += 1;
              out invI;
              unlock invI;
              evalr cas = %trimr(invI:'Z');
         Endsl;
           chain (cas) calall1;
             If not%found(calall1);
               return;
             Endif;
       Endfor;
               //output print file!
     Endif;
   return;
end-proc;
// =====================================================================
dcl-proc WriteDetail;
   dcl-pi *n;
      r     likeds(rug_t) const;
      units packed(7:0)   const;  // units placed in this write (may be groupQty or tail)
   end-pi;
   // TODO: write OP002WF detail record (exact field map from C12).
   // qty field on the record = units parameter.
   return;
end-proc;
// =====================================================================
dcl-proc WriteCarton;
   dcl-pi *n;
      boxId char(5)     const;
      tare  packed(7:3) const;
      cube  packed(9:0) const;
      wt    packed(9:2) const;
      units packed(7:0) const;
   end-pi;
   // TODO: AllocateCaseNumber + write OP003WF carton record (field map from C12).
   return;
end-proc;
// =====================================================================
dcl-proc WriteRoll;
   dcl-pi *n;
      r     likeds(rug_t) const;
      rugWt packed(9:2)   const;
   end-pi;
   // TODO: a rolled unit still needs a case number + detail/carton record,
   //   just no box/tare. Field map from C12.
   return;
end-proc;
// ===================================================================== 