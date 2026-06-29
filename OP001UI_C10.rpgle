       ctl-opt option(*nodebugio:*srcstmt:*nounref) dftactgrp(*no);
      * 06/03/08 RWilson Casing for Pick & Pack
      * 09/11/08 RWilson Add BCMST2P for grouping of Walmart pick & pack items
      *                  Also add some special code for JCP Catalog
      *                  Use b2al02 roll flag to also determine roll
      * 10/17/08 RWilson Add rmboxxf to get ROLL info
      * 10/22/10 RWilson Add coding for Kmart drop ship
      * 08/01/11 RWilson Add BBB casepack
      * 10/05/11 RWilson change CASEFILE to CALALL1, to include member CASEHIST
      * 10/06/11 RWilson change the hunt for unused case numbers to 5000 tries
      * 11/22/11 RWilson add NXTPT# data area
      * 07/23/12 RWilson make style E2290 for PO 2462239 case in 2 pieces.
      * 11/30/12 RWilson check inv#4 before incrementing
      * 02/07/13 RWilson change drop ship working to just DROPS in TIME
      * 01/06/14 RWilson make cascnt get new invoice for over 999
      * 09/29/15 RWilson if the cube from INVMST is 0, make it 1
      * 12/13/16 TMcAdam Add Wayfair
      * 02/16/17 TMcAdam Add Amazon
      * 02/27/17 TMcAdam Add Hayneedle
      * 02/28/17 TMcAdam Add Joss & Main
      * 06/12/17 TMcAdam Add AllModern
      * 10/23/17 TMcAdam Use PCOST from OP001WF instead of PRICE from
      *                  INVMST, because of the Wayfair 10% discount issue.
      * 12/13/17 TMcAdam Add Overstock
      * 01/04/18 TMcAdam Add BBB.COM for BBB DVS
      * 10/08/18 TMcAdam Add AMAZONP for Amazon Procurement
      * 04/02/19 RWilson - change to check barcode 2 for ROLL
      *                    test_tare will check xqty
      *                    get_tare will check qty
      * 06/06/19 RWilson for POUND, RACK, & SRACK, overlay weight
      *                  the weight for these is more than 99.99 pounds.
      * 10/23/19 RWilson add Home Depot direct ship
      * 11/09/20 RWilson for POUND, RACK, & SRACK, use file OP001PF as x-ref
      * 03/25/21 RWilson add Lowes.com
      **11/08/21 AShrader Use QGPL/MAXCUBE data area to replace hardcoding
      * 05/19/22 RWilson do fixes for OP001PF weight more than 99 pounds
      *                  in99 controls multiplying weight times .01
      * 10/10/23 CMunday Changed JCPENNEYDS to be JCP.COM
      * 10/26/23 RWilson Change to way Kohls direct is determined
      * 01/28/25 AShrader Check RMBOXXF for AS1,AS2 to force single case.
      * 08/28/25 CMunday Removed SPP204L1
      * 11/25/25 AShrader added chain to OP004PF2 if %subst(sorsq:6:3) = '30X'
      * 06/10/26 AShrader added save variables for cube and weight.
      ***************************************************************
     fop001l8   if   e           k disk
     finvmst    if   e           k disk
     fsh241f    if   e           k disk
     fop004pf   if   e           k disk
     fop004pf2  if   e           k disk
     faccrec    if   e           k disk    prefix(a_)
     fcalall1   if   e           k disk    prefix(c)
     fbcmst2p   if   e           k disk    prefix(b2)
     frmboxxf   if   e           k disk
     fcust_stor if   e           k disk
     fop017w2l2 if   e           k disk
     fop017w3   if   e           k disk
     fop001pf   if   e           k disk
     fop002wf   o    e             disk
     fop003wf   o    e             disk
     Fqsysprt   o    f  132        printer oflind(*inof)
     Dpoline2          s              2
     dGroupQty         s              3  0
     dneednext         s              1
     dcasecube         s              7  0
     dcasepounds       s              7  2
     dtestcube         s              7  0
     dtestlbs          s              9  4
     dspinqty          s              5  0
     dcompqty          s              5  0
     dthisqty          s              5  0
     dsavcu#           s              3  0
     dcartlbs          s              7  2
     dpiktlbs          s              7  2
     dwgt_2            s              5  2
     dxweight          s              5  2
     dxx_lbs           s              7  0
     dT$               s              9  2
     dtryit            s              1  0
     dcomplete         s              1
     dleftover         s              1
     dtestx            s              9  0
     dmaxcube          s              7  0
        dcl-s save_maxcube zoned(7:0);
        dcl-s save_opmxcb zoned(7:0);
     dmaxpounds        s              7  0
     dhunt             s              1
     dhunt#            s              6  0
     dfactory          s             10
     dholdstore        s              4
     Dwmt_cube         s              5  0
     Davg_case         s              9  4
     Dcvt_date         s               d
        dcl-ds *n;
          max_cube zoned(5:0) dtaara('QGPL/MAXCUBE');
        end-ds;
      *==================================================================
      * Named constants  (Commit 1 - values unchanged; see COMMIT1 doc)
      *==================================================================
        dcl-c CUST_WMT_PP    const('WALMARTP&P');
        dcl-c CUST_WMT_DVS   const('WALMARTDVS');
        dcl-c CUST_WMT_COM   const('WALMARTCOM');
        dcl-c CUST_WALMART   const('WALMART');
        dcl-c CUST_KOHLS     const('KOHLS');
        dcl-c CUST_KOHLS_DSN const('KOHLSDSN');
        dcl-c CUST_WAYFAIR   const('WAYFAIR');
        dcl-c CUST_AMAZON    const('AMAZON');
        dcl-c CUST_AMAZONP   const('AMAZONP');
        dcl-c CUST_JCP_COM   const('JCP.COM');
        dcl-c CUST_JCPENNEY  const('JCPENNEY');
        dcl-c CUST_COSTCO    const('COSTCO');
        dcl-c CUST_TARGET    const('TARGET');
        dcl-c CUST_CLOSEOUTS const('CLOSEOUTS');
        dcl-c CUST_JOSS_MAIN const('JOSS&MAIN');
        dcl-c CUST_HOMEDEPOT const('HOME DEPOT');
        dcl-c CUST_LOWES_COM const('LOWES.COM');
        dcl-c SRC_INVOIN     const('INVOIN');
        dcl-c SRC_NXTPT      const('NXTPT#');
        dcl-c LOT_WMRET      const(' WMRET');
        dcl-c SORT_30X       const('30X');
        dcl-c SORT_MANUAL    const('Manual');
        dcl-c LBL_FACTORY    const('FACTORY');
        dcl-c RTYPE_PICK     const('P');
        dcl-c BOX_ROLL       const('ROLL');
        dcl-c BOX_AS1        const('AS1');
        dcl-c BOX_AS2        const('AS2');
        dcl-c STY_POUND      const('POUND');
        dcl-c STY_RACK       const(' RACK');
        dcl-c STY_SRACK      const('SRACK');
        dcl-c STY_PRTRN      const('PRTRN');
        dcl-c STY_RRTRN      const('RRTRN');
        dcl-c PFX_KOLDS      const('KOLDS');
        dcl-c PFX_WMDVS      const('WMDVS');
        dcl-c PFX_TDD        const('TDD');
        dcl-c MAX_CASE_TRIES const(5000);
        dcl-c MAX_CARTON_SEQ const(999);
        dcl-c NXTPT_WRAP_HI  const(999999);
        dcl-c NXTPT_WRAP_LO  const(2001);
        dcl-c CUBE_T1        const(1530);
        dcl-c CUBE_T2        const(2880);
        dcl-c CUBE_T3        const(3840);
        dcl-c CUBE_T4        const(4800);
        dcl-c CUBE_T6        const(6120);
        dcl-c CUBE_T7        const(9945);
        dcl-c TARE_T1        const(0.97);
        dcl-c TARE_T2        const(2.070);
        dcl-c TARE_T3        const(2.230);
        dcl-c TARE_T4        const(2.717);
        dcl-c TARE_T5        const(2.740);
        dcl-c TARE_T6        const(3.37);
        dcl-c TARE_T7        const(3.91);
        dcl-c TARE_DEFAULT   const(4);
        dcl-c CU_WEIGHT_TRIG const(4800);
        dcl-c CU_30X_TRIG    const(9945);
        dcl-c CARTON_MAX_DFLT const(4800);
        dcl-s WM_RETAIL     ind;   // was *in23 - WMRET cube mode
        dcl-s USE_30X_MAX   ind;   // was *in42 - 30X carton-max override
        dcl-s SKUMAX_ON     ind;   // was *in49 - per-carton SKU limit active
        dcl-s WGT_FROM_XREF ind;   // was *in99 - weight from OP001PF (lbs)
        dcl-s ItsARoll char(1);   // roll flag set by DetermineRollItem; read by tare procs

     Iinvfmt
     I              weight                      iweight
      *
     c                   read      op001l8                                lr
B001 c                   if        *inlr = *off
 001 c                   exsr      custsetup
 001 c                   exsr      dupcheck
E001 c                   endif                                              lr =
     c                   eval      neednext = 'Y'
B001 c                   dow       *inlr = *off
B002 c                   if        neednext = 'Y'
 002 c                   exsr      nextptkt
E002 c                   endif                                              need
B002 c                   if        opxcub = 'Y'
 002 c                   exsr      changecube
E002 c                   endif
 001 c                   exsr      caseit
 001 c     wrkkey2       reade     op001l8                                11
B002 c                   If        *in11 = *on
B003 c                   if        casecube > 0
 003 c                   exsr      Closecarton
E003 c                   endif
 002 c                   eval      *in11 = *off
 002 c     wrkkey2       Setgt     op001l8
 002 c     wrkkey        reade     op001l8                                10
B003 c                   if        *in10 = *on
B004 c                   if        casecube > 0
 004 c                   exsr      Closecarton
E004 c                   endif
 003 c                   eval      neednext = 'Y'
 003 c                   eval      *in10 = *off
 003 c     wrkkey        setgt     op001l8
 003 c     cusomer       reade     op001l8                                12
B004 c                   If        *in12 = *on
 004 c     cusomer       setgt     op001l8
 004 c                   read      op001l8                                lr
B005 c                   if        *inlr = *off
 005 c                   exsr      custsetup
 005 c                   exsr      dupcheck
E005 c                   endif                                              lr =
X004 c                   Else                                               12 =
 004 c                   Exsr      dupcheck
E004 c                   Endif                                              12 =
E003 c                   endif                                              10 =
E002 c                   endif                                              11 =
E001 c                   enddo                                              lr d
      *---------------------------------------------------------------------
     c     *inzsr        begsr
      *
     c                   eval      *inof = *on
     c                   time                    tim               6 0
      *
     c     wrkkey        klist
     c                   kfld                    cusomer
     c                   kfld                    sort1
     c                   kfld                    sort2
     c                   kfld                    str#
     c                   kfld                    po#
      *
     c     wrkkey2       klist
     c                   kfld                    cusomer
     c                   kfld                    sort1
     c                   kfld                    sort2
     c                   kfld                    str#
     c                   kfld                    po#
     c                   kfld                    sortsq
      *
     c     invkey        klist
     c                   kfld                    deptno
     c                   kfld                    lotno
     c                   kfld                    color
      *
     c     acckey        klist
     c                   kfld                    a_custcd
     c                   kfld                    a_storno
     c                   kfld                    a_ordno
      *
     c     wrk4key2      klist
     c                   kfld                    cusomer
     c                   kfld                    opstyx
     c                   kfld                    opsizx
      *
     c     b2key         klist
     c                   kfld                    b2b2cus#
     c                   kfld                    b2b2styl
     c                   kfld                    b2b2isiz
     c                   kfld                    b2b2icol
      *
     c     cu_key        klist
     c                   kfld                    custcd
     c                   kfld                    store#
      *
     c                   eval      cartlbs = 0
     c                   Eval      casepounds = 0
     c                   Eval      factory = LBL_FACTORY
      *
           in *dtaara;
     c                   endsr
      *---------------------------------------------------------------------
     c     custsetup     begsr
         WM_RETAIL = *off;
      * indicator 40's are for next case number
     c                   eval      USE_30X_MAX = *off
     c                   eval      SKUMAX_ON = *off
     c                   Clear                   SkuMax
     c     cusomer       chain     op004r
B001 c                   if        %found
B002 c                   If        sort1 = SORT_MANUAL
 002 c                   Eval      opupac = *blanks
E002 c                   Endif
 001 c                   eval      maxcube = opmxcb
 001 c                   eval      maxpounds  = opmxlb
                         save_maxcube  = maxcube ;
                         save_opmxcb   = opmxcb  ;

E001 c                   endif
B001 c                   If        opflg1 <> *blanks
 001 c                   Eval      SKUMAX_ON = *on
 001 c                   Move      opflg1        SkuMax            3 0
E001 c                   Endif
           if lot# = LOT_WMRET;
                OPPO#  = po#;
                OPSTORE = str#;
                OPCUST = cusomer;
                cvt_date = %date(orddte:*MDY);
                OPPOD = %dec(cvt_date);
                chain (OPPO#:OPSTORE:OPCUST:OPPOD) op017w2l2;
                if %found(op017w2l2);
                   WM_RETAIL = *on;
                   opxcub = 'Y';
                   if OPTPALT > 0;
                      chain (opdesc:oppo#:opstore:oppod) op017w3;
                      if %found(op017w3);
                         eval(H) avg_case = opqty / optpalt + .49;
                         wmt_cube = max_cube / avg_case;
                      endif;
                   endif;
                endif;
           endif;
     c                   endsr
      *---------------------------------------------------------------------
     c     changecube    begsr
      * get cube for cust/style/size
         if catdpt <> *blanks;
            deptno = catdpt;
         else;
            if WM_RETAIL = *on;
              deptno = dpno;
            endif;
         endif;
     c                   eval      lotno  = lot#
     c                   eval      color  = clr
     c     invkey        chain     invfmt
B001 c                   if        %found
B002 c                   if        cu#in = 0
 002 c                   eval      cu#in = 1
E002 c                   endif
         chain (deptno:style:lotno) op001pf;
         if %found(op001pf);
            xx_lbs = x@pounds;
            WGT_FROM_XREF = *on;
         else;
            xx_lbs = iweight;
            WGT_FROM_XREF = *off;
         endif;
         if WGT_FROM_XREF = *off;
           if cu#in = CU_WEIGHT_TRIG and (xx_lbs *.01) > maxpounds;
             maxpounds = (xx_lbs * .01) + 1;
             opmxlb    = (xx_lbs * .01) + 1;
           endif;
         else;
           if cu#in = CU_WEIGHT_TRIG and (xx_lbs) > maxpounds;
             maxpounds =  xx_lbs + 1;
             opmxlb    =  xx_lbs + 1;
           endif;
         endif;
B002 c                   If        USE_30X_MAX = *on
 002 c                             and cu#in = CU_30X_TRIG
 002 c                   Eval      cu#in = max_cube
E002 c                   Endif
          if WM_RETAIL = *on;
             if wmt_cube > 0;
                cu#in = wmt_cube;
             endif;
          endif;
B002 c*                  If        cusomer = 'TARGET'
 002 c*                            And po# = '2462239 '
 002 c*                            and %subst(lot#:1:5) = 'E2290'
 002 c*                  Eval      cu#in = 2880
E002 c*                  Endif
         if WM_RETAIL = *on;
            cu#in = wmt_cube;
         endif;

         // anytime the INVMST cubic inches are over the max cube, make cubic in
         if cu#in > opmxcb;
            cu#in = opmxcb;
         endif;

 001 c                   eval      opstyx = %triml(style)
 001 c                   eval      opsizx = %triml(size)
 001 c     wrk4key2      chain     op004r2
B002 c                   if        not%found
B003 c                   if        cusomer = CUST_JCPENNEY
 003 c                   eval      opstyx = 'C'+ %subst(opstyx:1:4)
 003 c     wrk4key2      chain     op004r2
E003 c                   endif
E002 c                   endif
B002 c                   if        %found
B003 c                   if        maxcube <> opmxcb
 003 c                             and casecube > 0
 003 c                   exsr      Closecarton
E003 c                   endif


 002 c                   eval      maxcube = opmxcb
     c
X002 c                   else                                               foun

B003 c                   if        maxcube  <> opmxcb
 003 c                             and casecube > 0
 003 c                   exsr      Closecarton
E003 c                   endif


E002 c                   endif
E001 c                   endif
     c                   endsr
      *---------------------------------------------------------------------
     c     nextptkt      begsr
     c                   eval      neednext = 'n'
     c                   eval      hunt = 'Y'
     c                   eval      hunt# = 0
B001 c                   dow       hunt = 'Y'
 001 c                   eval      hunt# = hunt# + 1
 001 c                   Select
WHEN c                   When      opnxt# = SRC_INVOIN
 001 c     *dtaara       define    invoin        inv#2             6 0
 001 c     *lock         in        inv#2
 001 c                   eval      inv#2 = inv#2 + 1
 001 c                   out       inv#2
 001 c                   Clear                   ccase#
 001 c                   move      inv#2         ccase#
WHEN c                   When      opnxt# = SRC_NXTPT
 001 c     *dtaara       define    NXTPT#        inv#4             6 0
 001 c     *lock         in        inv#4
B002 c                   If        inv#4 = NXTPT_WRAP_HI
 002 c                   Eval      inv#4 = NXTPT_WRAP_LO
E002 c                   Endif
 001 c                   eval      inv#4 = inv#4 + 1
 001 c                   out       inv#4
 001 c                   move      inv#4         ccase#
 001 c                   Endsl
 001 c                   Move      ccase#        case##            6 0
 001 c     ccase#        chain     calall1
B002 c                   if        not%found
 002 c                   eval      hunt = *blanks
E002 c                   endif
B002 c                   if        hunt# > MAX_CASE_TRIES
B003 c                   if        *inof = *on
 003 c                   except    prtof
 003 c                   except    prtdup
 003 c                   eval      *inof = *off
E003 c                   endif
 002 c                   eval      hunt = *blank
 002 c                   eval      *inlr = *on
E002 c                   endif
E001 c                   enddo
      *
     c                   eval      cascnt = 1
     c                   eval      casseq = 0
     c                   eval      piktlbs = 0
     c                   eval      t$ = 0
           ResolveShipCustomer();
     c                   endsr
      *---------------------------------------------------------------------
     c     caseit        begsr
     c                   eval      deptno = dpno
     c                   eval      lotno  = lot#
     c                   eval      color  = clr
     c     invkey        chain     invfmt
B001 c                   if        cu#in = 0
 001 c                   eval      cu#in = 1
E001 c                   endif
         chain (deptno:style:lotno) op001pf;
         if %found(op001pf);
            xx_lbs = x@pounds;
            WGT_FROM_XREF = *on;
         else;
            xx_lbs = iweight;
            WGT_FROM_XREF = *off;
         endif;

                  If %subst(sortsq:6:3) = SORT_30X;
                     chain (SORT_30X) op004pf2;
B003                    If        %found(op004pf2);
 003 c                   Eval      USE_30X_MAX = *on
 003 c                   eval      maxcube = opmxcb
                        Else;
                          maxcube = CARTON_MAX_DFLT;
E003                    Endif;
E003              Endif;

       // anytime the INVMST weight is over the max weight, make the weight = ma
         if WGT_FROM_XREF = *off;
            if cu#in = CU_WEIGHT_TRIG and (xx_lbs * .01) > maxpounds;
              maxpounds  = (xx_lbs * .01) + 1;
              opmxlb     = (xx_lbs * .01) + 1;
            endif;
         else;
            if cu#in = CU_WEIGHT_TRIG and (xx_lbs) > maxpounds;
              maxpounds  = xx_lbs + 1;
              opmxlb     = xx_lbs + 1;
            endif;
         endif;

B001 c*                  If        *in42 = *on
 001 c*                            and cu#in = 9945
 001 c*                  Eval      cu#in = max_cube
E001 c*                  Endif
          if WM_RETAIL = *on;
             if wmt_cube > 0;
                cu#in = wmt_cube;
             endif;
          endif;

             // anytime the INVMST cubic inches are over the max cube, make cubic in
             if cu#in > opmxcb;
               cu#in = opmxcb;
             endif;
B001 c*                  if        cusomer = 'WALMARTP&P'
 001 c*                            And caseqty <> 0
 001 c*                  Eval      cu#in = max_cube / caseqty
E001 c*                  Endif
B001 c*                  If        cusomer = 'TARGET'
 001 c*                            And po# = '2462239 '
 001 c*                            and %subst(lot#:1:5) = 'E2290'
 001 c*                  Eval      cu#in = 2880
E001 c*                  Endif
     c                   Eval      b2b2cus# = savcu#
     c                   Eval      b2b2styl = %triml(style)
     c                   Eval      b2b2isiz = %triml(size)
     c                   MoveL     color         b2b2icol
     c                   Eval      GroupQty = 1
     c                   Clear                   b2b2al02
     c     b2key         Chain     bcmst2p
B001 c                   If        %found
B002 c                   If        b2B2NM06 <> 0
 002 c                   Eval      GroupQty = b2b2nm06
E002 c                   Endif
E001 c                   Endif
B001 c*                  If        cusomer = 'TARGET'
 001 c*                            and po# = '2462239 '
 001 c*                            and %subst(lot#:1:5) = 'E2290'
 001 c*                  Eval      groupqty = 2
E001 c*                  Endif
      *                  If        (iweight*.01) > 40
      *                  Eval      xweight = 40
      *                  Else
         if WGT_FROM_XREF = *off;
     c                   Eval      xweight = xx_lbs  * .01
         else;
     c                   Eval      xweight = xx_lbs
         endif;
      *                  Endif
           ComputeTrialTare();
B001 c                   if        (casecube + (GroupQty * cu#in)) > maxcube
 001 c                             or testlbs > maxpounds
 001 c                   exsr      Closecarton
E001 c                   endif
     c                   exsr      PackPickLine
     c                   endsr
      *---------------------------------------------------------------------
     c     PackPickLine  begsr
      * Packs the current pick line (xqty units) into cartons. Verbatim
      * from caseit; behavior unchanged. Calls nextptkt/addrecord/Closecarton.
     c                   eval      spinqty = xqty
     c                   eval      compqty = xqty
B001 c                   do        compqty
B002 c                   if        spinqty > 0
B003 c                   if        neednext = 'Y'
 003 c                   exsr      nextptkt
E003 c                   endif                                              need
 002 c                   eval      thisqty = 0
 002 c                   eval      tryit = 1
B003 c                   dow       tryit = 1
           ComputeTrialTare();
B004 c                   if        (casecube + (GroupQty * cu#in)) = maxcube
 004 c                             and testlbs <= maxpounds
 004 c                             or (casecube + (GroupQty * cu#in)) <= maxcube
 004 c                             and testlbs = maxpounds
     c                             or bxinum = BOX_AS1
     c                             or bxinum = BOX_AS2
 004 c                   eval      tryit = 0
 004 c                   eval      casecube = casecube + (GroupQty * cu#in)
 004 c                   eval      casepounds = casepounds +(GroupQty * xweight)
 004 c                   eval      thisqty = thisqty + GroupQty
         if WGT_FROM_XREF = *off;
 004 c                   eval      wgt_2   = xx_lbs  * .01
         else;
 004 c                   eval      wgt_2   = xx_lbs
         endif;
      ***                   eval      t$ = t$ + price
 004 c                   eval      t$ = t$ + pcost
 004 c                   eval      complete = 'Y'
 004 c                   exsr      addrecord
B005 c                   If        cusomer <> CUST_WMT_PP
 005 c                             Or cusomer = CUST_WMT_PP
 005 c                             and GroupQty = 1
 005 c                   eval      spinqty = spinqty - GroupQty
     c                   Add       1             piece_count
X005 c                   Else
 005 c                   Sub       1             spinqty
     c                   Add       1             piece_count
E005 c                   Endif
X004 c                   else
B005 c                   if        (casecube + (GroupQty * cu#in)) < maxcube
 005 c                             and testlbs < maxpounds
 005 c                   eval      casecube = casecube + (GroupQty * cu#in)
 005 c                   Eval      casepounds = casepounds +(GroupQty * xweight)
 005 c                   eval      thisqty = thisqty + GroupQty
        if WGT_FROM_XREF = *off;
 005 c                   eval      wgt_2   = xx_lbs  * .01
        else;
 005 c                   eval      wgt_2   = xx_lbs
        endif;
      ***                   eval      t$ = t$ + (price  * GroupQty)
 005 c                   eval      t$ = t$ + (pcost  * GroupQty)
B006 c                   If        cusomer <> CUST_WMT_PP
 006 c                             Or cusomer = CUST_WMT_PP
 006 c                             and GroupQty = 1
 006 c                   eval      spinqty = spinqty - GroupQty
     c                   Add       1             piece_count
X006 c                   Else
 006 c                   Sub       1             spinqty
     c                   Add       1             piece_count
E006 c                   Endif
X005 c                   else
B006 c                   if        (casecube + (GroupQty * cu#in)) > maxcube
 006 c                             or testlbs > maxpounds
 006 c                   eval      complete = 'Y'
 006 c                   exsr      addrecord
E006 c                   endif
E005 c                   endif                                              < ma
E004 c                   endif                                              = ma
B004 c                   if        spinqty = *zeros
 004 c                   eval      tryit = 0
E004 c                   endif
E003 c                   enddo                                              dow
E002 c                   endif                                              spin
B002 c                   if        thisqty <> 0
 002 c                   eval      complete = 'N'
 002 c                   exsr      addrecord
E002 c                   endif
            maxcube = save_maxcube;
            opmxcb  = save_opmxcb;
E001 c                   enddo                                              do q
     c                   endsr
      *---------------------------------------------------------------------
     c     addrecord     begsr
B001 c                   If        SkuCount = SkuMax
 001 c                             and SKUMAX_ON = *on
B002 c                   If        casecube > 0
 002 c                   Exsr      CloseCarton
E002 c                   Endif
 001 c                   Clear                   skucount
E001 c                   Endif
     c                   eval      rtype  = RTYPE_PICK
     c                   Clear                   caseno
     c                   move      ccase#        caseno
     c                   eval      casseq = casseq + 1
     c                   eval      custcd = compid
     c                   eval      store# = str#
     c                   eval      ordno  = po#
     c                   eval      odate  = orddte
     c                   eval      cdate  = candte
     c                   eval      sdate  = rshdte
     c                   eval      rdate  = entdte
     c                   eval      phdate = *zeros
     c                   eval      shdate = *zeros
     c                   eval      shpvia = *blanks
     c                   eval      empclk = savcu#
     c                   eval      qty    = thisqty
     c                   eval      uprice = pcost
     c                   move      lnsku         cpolin
           ApplyCustomerFields();

       //        If %found(spp204l1) and SPSZIDF in %list('9':'X':'L');
       //               CSCUIN = '4800';
       //        Else;
                            DetermineOrderType();
       //        Endif;

     c*                   exsr      get_otype
     c                   write     op002wr
     c                   Add       1             SkuCount          3 0
     c                   Clear                   sman
     c                   Clear                   boxsz
     c                   Clear                   cwgt
     c     thisqty       mult(h)   wgt_2         thiswgt           7 2
     c                   eval      cartlbs = cartlbs + thiswgt
     c                   eval      thisqty = 0
B001 c                   if        complete = 'Y'
 001 c                   exsr      Closecarton
E001 c                   endif
B001 c                   If        SkuCount = SkuMax
 001 c                             and SKUMAX_ON = *on
B002 c                   If        casecube > 0
 002 c                   Exsr      CloseCarton
E002 c                   Endif
 001 c                   Clear                   skucount
     c                   Clear                   piece_count       5 0
E001 c                   Endif
     c                   endsr
      *---------------------------------------------------------------------
     c     Closecarton   begsr
           ApplyCartonTare();
     c                   Eval      casepounds = 0
     c                   eval      caswgt = cartlbs
     c                   eval      creproc = rreproc
      *                  If        opupac <> 'N'
     c                   Eval      cccube = casecube
           DerivePo22();
     c                   write     op003wr
      *                  Endif
     c                   eval      casecube = 0
     c                   eval      cascnt = cascnt + 1
     c                   eval      casseq = 0
     c                   eval      piktlbs = piktlbs + cartlbs
     c                   eval      cartlbs = 0
     c                   Eval      SkuCount = 0
B001 c                   If        cascnt = MAX_CARTON_SEQ
 001 c                   Eval      neednext = 'Y'
E001 c                   Endif
     c                   endsr
      *---------------------------------------------------------------------
     c     dupcheck      begsr
     c                   eval      a_custcd = compid
     c                   eval      a_storno = str#
     c                   eval      a_ordno  = po#
     c     acckey        chain     accrec
B001 c                   if        %found(Accrec)
     **     If a_storno = 'KOLDS1' OR a_storno = 'KOLDS3';              // for Kohls.com PO's
            if %subst(a_storno:1:5) = PFX_KOLDS;
                If a_ordate = Orddte;
B002 c                   if        *inof = *on
 002 c                   except    prtof
 002 c                   eval      *inof = *off
E002 c                   endif
 001 c                   except    prtdupacc
                Endif;
            Else;
B002 c                   if        *inof = *on
 002 c                   except    prtof
 002 c                   eval      *inof = *off
E002 c                   endif
 001 c                   except    prtdupacc
            Endif;
E001 c                   endif
     c                   endsr
      *---------------------------------------------------------------------
      *---------------------------------------------------------------------
      *---------------------------------------------------------------------
      *---------------------------------------------------------------------
     Oqsysprt   e            prtof          1  3
     O                                            5 'Date:'
     O                       udate         y  +   1
     o                                           56 'Pick & Pack Casing'
     o                                              ' Program Errors OP001UI'
     o                                          100 'Page:'
     o                       page          z
     o          e            prtof          2
     o                                            5 'Time:'
     o                       tim              +   1 ' 0:  :  '
     o          e            prtdup         2
     o                                              'The new case number '
     o                                              'is encountering duplicates'
     o                                              ', do no run update.'
     o                       ccase#           +   2
     o          e            prtdupacc      2
     o                                              'The Store/Order combina'
     o                                              'tion is already in ACCREC.'
     o                       a_storno         +   2
     o                       a_ordno          +   2
     O                       a_invno          +   2
     O                       a_ordate         +   2 '  /  /  ' 
      *==================================================================
      * DetermineOrderType  (was subroutine get_otype) - globals only,
      * body unchanged. MOVE preserved verbatim (NOT %char).
      *==================================================================
       dcl-proc DetermineOrderType;
     c     cu_key        chain     cust_stor
B001 c                   if        %found(cust_stor)
 001 c                   move      cuuty#        CSCUIN
X001 c                   else
 001 c                   eval      CSCUIN = *blanks
E001 c                   endif
       end-proc;
      *==================================================================
      * ApplyCartonTare  - adds tier tare to cartlbs (globals only; body verbatim).
      *==================================================================
       dcl-proc ApplyCartonTare;
           ItsARoll = *blanks;
        if style <> STY_POUND and style <> STY_RACK and style <> STY_SRACK
          and style <> STY_PRTRN and style <> STY_RRTRN;
           DetermineRollItem();
B001 c                   If        ItsARoll <> 'Y'
     c                             or cu#in < max_cube and piece_count > 1
 001 c                   Move      'N'           Selected          1
 001 c                   Select
WHEN c                   When      casecube <= CUBE_T1
 001 c                   Eval      cartlbs = cartlbs + TARE_T1
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      casecube <= CUBE_T2
 001 c                   Eval      cartlbs = cartlbs + TARE_T2
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      casecube <= CUBE_T3
 001 c                   Eval      cartlbs = cartlbs + TARE_T3
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      casecube <= CUBE_T4
 001 c                   Eval      cartlbs = cartlbs + TARE_T4
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      casecube <= max_cube
 001 c                   Eval      cartlbs = cartlbs + TARE_T5
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      casecube <= CUBE_T6
 001 c                   Eval      cartlbs = cartlbs + TARE_T6
 001 c                   Eval      selected = 'Y'
WHEN c                   When      casecube <= CUBE_T7
 001 c                   Eval      cartlbs = cartlbs + TARE_T7
 001 c                   Eval      selected = 'Y'
 001 c                   Endsl
B002 c                   If        Selected = 'N'
 002 c                   Eval      cartlbs = cartlbs + TARE_DEFAULT
E002 c                   Endif
      *
E001 c                   Endif
         endif;
       end-proc;
      *==================================================================
      * ComputeTrialTare  - computes trial testcube/testlbs (globals only; body verbatim).
      *==================================================================
       dcl-proc ComputeTrialTare;
           DetermineRollItem();
B001 c                   If        ItsARoll <> 'Y'
     c                             or cu#in < max_cube and piece_count > 1
 001 c                   Eval      testcube = casecube + (GroupQty * cu#in)
        if WGT_FROM_XREF = *off;
 001 c                   Eval      testlbs = casepounds+((xx_lbs *.01*GroupQty))
        else;
 001 c                   Eval      testlbs = casepounds+((xx_lbs *GroupQty))
        endif;
 001 c                   Move      'N'           Selected          1
 001 c                   Select
WHEN c                   When      testcube <= CUBE_T1
 001 c                   Eval      testlbs = testlbs + TARE_T1
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      testcube <= CUBE_T2
 001 c                   Eval      testlbs = testlbs + TARE_T2
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      testcube <= CUBE_T3
 001 c                   Eval      testlbs = testlbs + TARE_T3
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      testcube <= CUBE_T4
 001 c                   Eval      testlbs = testlbs + TARE_T4
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      testcube <= max_cube
 001 c                   Eval      testlbs = testlbs + TARE_T5
 001 c                   Eval      Selected = 'Y'
WHEN c                   When      casecube <= CUBE_T6
 001 c                   Eval      testlbs = testlbs + TARE_T6
 001 c                   Eval      selected = 'Y'
WHEN c                   When      casecube <= CUBE_T7
 001 c                   Eval      testlbs = testlbs + TARE_T7
 001 c                   Eval      selected = 'Y'
 001 c                   Endsl
B002 c                   If        Selected = 'N'
 002 c                   Eval      testlbs = testlbs + TARE_DEFAULT
E002 c                   Endif
      *
E001 c                   Endif
       end-proc;
      *==================================================================
      * DetermineRollItem - sets global ItsARoll; RMBOXXF chain also
      * leaves BXINUM for caseit AS1/AS2. (De-duped from the tare procs;
      * historical commented spp204l1 used qty in Get_Tare, Xqty in Test_Tare.)
      *==================================================================
       dcl-proc DetermineRollItem;
     c                   Clear                   ItsARoll
     c*                  Eval      spsize = %triml(size)
     c*    spsize        Chain     spp204l1
B001 c*                  If        %found
 001 c*                            And sprlfg = 'Y'
 001 c*                            And Xqty = 1
 001 c*                  Eval      ItsARoll = 'Y'
E001 c*                  Endif
      *
     c     b2key         Chain     rmboxxf
B001 c                   If        %found
 001 c                             and bxinum = BOX_ROLL
 001 c                   Eval      ItsARoll = 'Y'
E001 c                   Endif
      *
B001 c                   If        not %found(rmboxxf)
 001 c                             or %found(rmboxxf) and bxinum = ' '
 001 c     b2key         Chain     bcmst2p
B002 c                   If        %found and b2b2al03 = BOX_ROLL
 002 c                   Eval      ItsARoll = 'Y'
E002 c                   Endif
E001 c                   Endif
      *
       end-proc;
      *==================================================================
      * DerivePo22 - sets po#22 from the customer's PO-format rule.
      * 4 specials, one sort1+sortst5 group, else blank. (Was the nested
      * if/else in Closecarton; behavior unchanged - see COMMIT4 doc.)
      *==================================================================
       dcl-proc DerivePo22;
         select;
         when cusomer = CUST_WMT_PP and sort2 <> *blanks;
              po#22 = sort2;
         when cusomer = CUST_COSTCO;
              po#22 = sort1 + sort2;
         when cusomer = CUST_TARGET and %subst(str#:1:3) = PFX_TDD;
              po#22 = sort2;
         when (cusomer = CUST_WMT_COM and %subst(str#:1:5) = PFX_WMDVS)
               or cusomer = CUST_WMT_DVS
               or cusomer = CUST_KOHLS_DSN
               or cusomer = CUST_WAYFAIR
               or cusomer = CUST_JCP_COM
               or cusomer = CUST_AMAZON     or cusomer = CUST_AMAZONP
               or cusomer = CUST_JOSS_MAIN
               or cusomer = CUST_HOMEDEPOT
               or cusomer = CUST_LOWES_COM;
              po#22 = sort1 + sortst5;
         other;
              clear po#22;
         endsl;
       end-proc;
      *==================================================================
      * ResolveShipCustomer - maps the order's customer to its ship name
      * (SHCSTN) + code (savcu#) via SH241M/SH241F. WMT_PP/WMT_DVS only
      * remap when sh241m is not found; the DVS aliases remap always.
      *==================================================================
       dcl-proc ResolveShipCustomer;
     c     cusomer       chain     sh241m
         if not %found(sh241f);
            select;
            when cusomer = CUST_WMT_PP;
                 SHCSTN = CUST_WALMART;
                 chain shcstn sh241f;
            when cusomer = CUST_WMT_DVS;
                 SHCSTN = CUST_WMT_COM;
                 chain shcstn sh241f;
            endsl;
         endif;
         select;
         when cusomer = CUST_KOHLS_DSN;
              SHCSTN = CUST_KOHLS;
              chain shcstn sh241f;
         when cusomer = CUST_JCP_COM;
              SHCSTN = CUST_JCP_COM;
              chain shcstn sh241f;
         endsl;
     c                   move      shccde        savcu#
       end-proc;
      *==================================================================
      * ApplyCustomerFields - per-customer overrides of boxsz/sman/cwgt/
      * time/cpolin on the OP002WF record. Kept as the original cascade
      * of independent IFs ON PURPOSE: blocks are cumulative (e.g. a
      * Manual KMART J1 order hits the J1 block AND the Manual block, and
      * the later sman=catdpt overwrites). A SELECT would change that.
      *==================================================================
       dcl-proc ApplyCustomerFields;
B001 c                   If        Cusomer = CUST_COSTCO
 001 c                   Eval      poline2 = %subst(lnsku:2:2)
 001 c                   Move      poline2       cpolin
E001 c                   Endif
B001 c                   If        cusomer = CUST_JCPENNEY
 001 c                   Movel     catdpt        boxsz
 001 c                   Eval      sman = %subst(catdpt:2:2)+'C'
E001 c                   Endif
B001 c                   If        cusomer = CUST_TARGET
 001 c                   Eval      sman = catdpt
E001 c                   Endif
B001 c                   If        cusomer = CUST_CLOSEOUTS
 001 c                             Or cusomer = CUST_KOHLS
 001 c                             Or cusomer = CUST_WAYFAIR
 001 c                             Or cusomer = CUST_JOSS_MAIN
 001 c                   Eval      sman = catdpt
E001 c                   Endif
       end-proc;