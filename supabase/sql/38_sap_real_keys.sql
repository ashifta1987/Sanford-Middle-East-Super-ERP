-- sap tables whose primary key was stricter than SAP's (approved 13 Nov 2026): SAP key from the HANA export create.sql.
-- One link references one of these tables: ukd1_keyid_fkey (UKD1 -> OUKD), updated in 04_foreign_keys.sql to (company_code, TableName, KeyId). Applied to xhsfkbbcejgwvqxpqdgq by the migration team.
-- ADG1: was (company_code, AbsEntry, LogInstanc)
alter table sap."ADG1" drop constraint "adg1_pkey", add constraint "adg1_pkey" primary key (company_code, "AbsEntry", "ObjType", "ObjKey", "LogInstanc");
-- ADOC: was (company_code, DocEntry, LogInstanc)
alter table sap."ADOC" drop constraint "adoc_pkey", add constraint "adoc_pkey" primary key (company_code, "DocEntry", "ObjType", "LogInstanc");
-- AEC3: was (company_code, AbsEntry, LogInstanc)
alter table sap."AEC3" drop constraint "aec3_pkey", add constraint "aec3_pkey" primary key (company_code, "AbsEntry", "LogNum", "LogInstanc");
-- AEC5: was (company_code, AbsEntry, LogInstanc)
alter table sap."AEC5" drop constraint "aec5_pkey", add constraint "aec5_pkey" primary key (company_code, "AbsEntry", "LogNum", "LogInstanc");
-- AFAD: was (company_code, DocEntry, LogInstanc)
alter table sap."AFAD" drop constraint "afad_pkey", add constraint "afad_pkey" primary key (company_code, "DocEntry", "ObjType", "LogInstanc");
-- AKL1: was (company_code, AbsEntry)
alter table sap."AKL1" drop constraint "akl1_pkey", add constraint "akl1_pkey" primary key (company_code, "AbsEntry", "PickEntry", "LogInsac");
-- AKL2: was (company_code, AbsEntry, LogInstanc)
alter table sap."AKL2" drop constraint "akl2_pkey", add constraint "akl2_pkey" primary key (company_code, "AbsEntry", "PickEntry", "Pkl2LinNum", "LogInstanc");
-- AMRV: was (company_code, DocEntry, LogInstanc)
alter table sap."AMRV" drop constraint "amrv_pkey", add constraint "amrv_pkey" primary key (company_code, "DocEntry", "LogInstanc", "ObjType");
-- APJ1: was (company_code, StepCode, LogInstanc)
alter table sap."APJ1" drop constraint "apj1_pkey", add constraint "apj1_pkey" primary key (company_code, "DocEntry", "StepCode", "LogInstanc");
-- APKL: was (company_code, AbsEntry)
alter table sap."APKL" drop constraint "apkl_pkey", add constraint "apkl_pkey" primary key (company_code, "AbsEntry", "LogInstac");
-- ARCT: was (company_code, DocEntry, LogInstanc)
alter table sap."ARCT" drop constraint "arct_pkey", add constraint "arct_pkey" primary key (company_code, "DocEntry", "LogInstanc", "ObjType");
-- ATC1: was (company_code, AbsEntry)
alter table sap."ATC1" drop constraint "atc1_pkey", add constraint "atc1_pkey" primary key (company_code, "AbsEntry", "Line");
-- AVM1: was (company_code, AbsEntry)
alter table sap."AVM1" drop constraint "avm1_pkey", add constraint "avm1_pkey" primary key (company_code, "AbsEntry", "PropID");
-- AVM2: was (company_code, AbsEntry)
alter table sap."AVM2" drop constraint "avm2_pkey", add constraint "avm2_pkey" primary key (company_code, "AbsEntry", "ObjectId");
-- BAL1: was (company_code, AbsEntry)
alter table sap."BAL1" drop constraint "bal1_pkey", add constraint "bal1_pkey" primary key (company_code, "AbsEntry", "Instance");
-- BOT1: was (company_code, AbsEntry)
alter table sap."BOT1" drop constraint "bot1_pkey", add constraint "bot1_pkey" primary key (company_code, "AbsEntry", "BOENumber", "BoeType");
-- BTA1: was (company_code, AbsEntry)
alter table sap."BTA1" drop constraint "bta1_pkey", add constraint "bta1_pkey" primary key (company_code, "AbsEntry", "StaType");
-- CDIC: was (company_code, _Key)
alter table sap."CDIC" drop constraint "cdic_pkey", add constraint "cdic_pkey" primary key (company_code, "Namespace", "_Key");
-- CFN1: was (company_code, AbsEntry)
alter table sap."CFN1" drop constraint "cfn1_pkey", add constraint "cfn1_pkey" primary key (company_code, "AbsEntry", "ItemIndex");
-- CFUS: was (company_code, UserCode)
alter table sap."CFUS" drop constraint "cfus_pkey", add constraint "cfus_pkey" primary key (company_code, "FuncName", "UserCode");
-- CHFL: was (company_code, FldIndex)
alter table sap."CHFL" drop constraint "chfl_pkey", add constraint "chfl_pkey" primary key (company_code, "ObjName", "FldIndex");
-- CIN23: was (company_code, DocEntry, LineNum)
alter table sap."CIN23" drop constraint "cin23_pkey", add constraint "cin23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- CLC1: was (company_code, AbsEntry)
alter table sap."CLC1" drop constraint "clc1_pkey", add constraint "clc1_pkey" primary key (company_code, "AbsEntry", "ModObjKey");
-- CPI23: was (company_code, DocEntry, LineNum)
alter table sap."CPI23" drop constraint "cpi23_pkey", add constraint "cpi23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- CPL1: was (company_code, AbsEntry)
alter table sap."CPL1" drop constraint "cpl1_pkey", add constraint "cpl1_pkey" primary key (company_code, "AbsEntry", "LogId");
-- CPT1: was (company_code, AbsEntry)
alter table sap."CPT1" drop constraint "cpt1_pkey", add constraint "cpt1_pkey" primary key (company_code, "AbsEntry", "SubEntry");
-- CPV23: was (company_code, DocEntry, LineNum)
alter table sap."CPV23" drop constraint "cpv23_pkey", add constraint "cpv23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- CRD6: was (company_code, CardCode)
alter table sap."CRD6" drop constraint "crd6_pkey", add constraint "crd6_pkey" primary key (company_code, "CardCode", "CardPyName");
-- CSI23: was (company_code, DocEntry, LineNum)
alter table sap."CSI23" drop constraint "csi23_pkey", add constraint "csi23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- CSV23: was (company_code, DocEntry, LineNum)
alter table sap."CSV23" drop constraint "csv23_pkey", add constraint "csv23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- DGP1: was (company_code, AbsEntry)
alter table sap."DGP1" drop constraint "dgp1_pkey", add constraint "dgp1_pkey" primary key (company_code, "AbsEntry", "CardCode");
-- DGP2: was (company_code, AbsEntry)
alter table sap."DGP2" drop constraint "dgp2_pkey", add constraint "dgp2_pkey" primary key (company_code, "AbsEntry", "CondNum");
-- DGP3: was (company_code, AbsEntry)
alter table sap."DGP3" drop constraint "dgp3_pkey", add constraint "dgp3_pkey" primary key (company_code, "AbsEntry", "CondNum");
-- DGP5: was (company_code, AbsEntry)
alter table sap."DGP5" drop constraint "dgp5_pkey", add constraint "dgp5_pkey" primary key (company_code, "AbsEntry", "CondNum");
-- DLN23: was (company_code, DocEntry, LineNum)
alter table sap."DLN23" drop constraint "dln23_pkey", add constraint "dln23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- DOC23: was (company_code, DocEntry, LineNum)
alter table sap."DOC23" drop constraint "doc23_pkey", add constraint "doc23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- DPI23: was (company_code, DocEntry, LineNum)
alter table sap."DPI23" drop constraint "dpi23_pkey", add constraint "dpi23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- DPO23: was (company_code, DocEntry, LineNum)
alter table sap."DPO23" drop constraint "dpo23_pkey", add constraint "dpo23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- DRF23: was (company_code, DocEntry, LineNum)
alter table sap."DRF23" drop constraint "drf23_pkey", add constraint "drf23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- ECDW1: was (company_code, AbsEntry)
alter table sap."ECDW1" drop constraint "ecdw1_pkey", add constraint "ecdw1_pkey" primary key (company_code, "AbsEntry", "DocType", "ExNumData1", "ExNumData2");
-- ECM3: was (company_code, AbsEntry)
alter table sap."ECM3" drop constraint "ecm3_pkey", add constraint "ecm3_pkey" primary key (company_code, "AbsEntry", "LogNum");
-- ECM5: was (company_code, AbsEntry)
alter table sap."ECM5" drop constraint "ecm5_pkey", add constraint "ecm5_pkey" primary key (company_code, "AbsEntry", "LogNum");
-- EDG1: was (company_code, AbsEntry)
alter table sap."EDG1" drop constraint "edg1_pkey", add constraint "edg1_pkey" primary key (company_code, "AbsEntry", "ObjType", "ObjKey");
-- EFDW1: was (company_code, AbsEntry)
alter table sap."EFDW1" drop constraint "efdw1_pkey", add constraint "efdw1_pkey" primary key (company_code, "AbsEntry", "WhCode");
-- EML1: was (company_code, AbsEntry)
alter table sap."EML1" drop constraint "eml1_pkey", add constraint "eml1_pkey" primary key (company_code, "AbsEntry", "Line");
-- FLR1: was (company_code, AbsId)
alter table sap."FLR1" drop constraint "flr1_pkey", add constraint "flr1_pkey" primary key (company_code, "AbsId", "ColName");
-- FND1: was (company_code, AbsEntry)
alter table sap."FND1" drop constraint "fnd1_pkey", add constraint "fnd1_pkey" primary key (company_code, "AbsEntry", "Series");
-- GDP1: was (company_code, AbsEntry)
alter table sap."GDP1" drop constraint "gdp1_pkey", add constraint "gdp1_pkey" primary key (company_code, "AbsEntry", "PfsAbs");
-- IEI23: was (company_code, DocEntry, LineNum)
alter table sap."IEI23" drop constraint "iei23_pkey", add constraint "iei23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- IGE23: was (company_code, DocEntry, LineNum)
alter table sap."IGE23" drop constraint "ige23_pkey", add constraint "ige23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- IGN23: was (company_code, DocEntry, LineNum)
alter table sap."IGN23" drop constraint "ign23_pkey", add constraint "ign23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- INV23: was (company_code, DocEntry, LineNum)
alter table sap."INV23" drop constraint "inv23_pkey", add constraint "inv23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- IWB1: was (company_code, AbsEntry)
alter table sap."IWB1" drop constraint "iwb1_pkey", add constraint "iwb1_pkey" primary key (company_code, "AbsEntry", "LineNumber");
-- IWB2: was (company_code, AbsEntry)
alter table sap."IWB2" drop constraint "iwb2_pkey", add constraint "iwb2_pkey" primary key (company_code, "AbsEntry", "LineNumber");
-- IWZ1: was (company_code, AbsEntry)
alter table sap."IWZ1" drop constraint "iwz1_pkey", add constraint "iwz1_pkey" primary key (company_code, "AbsEntry", "AcctCode");
-- IWZ2: was (company_code, AbsEntry)
alter table sap."IWZ2" drop constraint "iwz2_pkey", add constraint "iwz2_pkey" primary key (company_code, "AbsEntry", "WhCode");
-- IWZ3: was (company_code, AbsEntry)
alter table sap."IWZ3" drop constraint "iwz3_pkey", add constraint "iwz3_pkey" primary key (company_code, "AbsEntry", "ItemCode", "WhCode");
-- MDC2: was (company_code, AbsEntry)
alter table sap."MDC2" drop constraint "mdc2_pkey", add constraint "mdc2_pkey" primary key (company_code, "AbsEntry", "ObjectType");
-- MIN1: was (company_code, AbsEntry)
alter table sap."MIN1" drop constraint "min1_pkey", add constraint "min1_pkey" primary key (company_code, "Entry", "DocType", "AbsEntry");
-- MIV1: was (company_code, AbsEntry)
alter table sap."MIV1" drop constraint "miv1_pkey", add constraint "miv1_pkey" primary key (company_code, "Entry", "DocType", "AbsEntry");
-- MSN1: was (company_code, AbsEntry)
alter table sap."MSN1" drop constraint "msn1_pkey", add constraint "msn1_pkey" primary key (company_code, "AbsEntry", "WhsCode");
-- MSN2: was (company_code, AbsEntry)
alter table sap."MSN2" drop constraint "msn2_pkey", add constraint "msn2_pkey" primary key (company_code, "AbsEntry", "PeriodID", "ItemCode");
-- MSN4: was (company_code, AbsEntry)
alter table sap."MSN4" drop constraint "msn4_pkey", add constraint "msn4_pkey" primary key (company_code, "AbsEntry", "ItemCode");
-- MSN5: was (company_code, AbsEntry)
alter table sap."MSN5" drop constraint "msn5_pkey", add constraint "msn5_pkey" primary key (company_code, "AbsEntry", "DocType", "DocEntry", "DocSubType");
-- OAGM: was (company_code, DocEntry)
alter table sap."OAGM" drop constraint "oagm_pkey", add constraint "oagm_pkey" primary key (company_code, "DocEntry", "ObjType");
-- OCRB: was (company_code, AbsEntry)
alter table sap."OCRB" drop constraint "ocrb_pkey", add constraint "ocrb_pkey" primary key (company_code, "Country", "BankCode", "Account", "CardCode");
-- ODW1: was (company_code, AbsEntry)
alter table sap."ODW1" drop constraint "odw1_pkey", add constraint "odw1_pkey" primary key (company_code, "AbsEntry", "DocType");
-- OEI23: was (company_code, DocEntry, LineNum)
alter table sap."OEI23" drop constraint "oei23_pkey", add constraint "oei23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- OPCT: was (company_code, TmplCode)
alter table sap."OPCT" drop constraint "opct_pkey", add constraint "opct_pkey" primary key (company_code, "DocEntry");
-- OPTR: was (company_code, AbsEntry)
alter table sap."OPTR" drop constraint "optr_pkey", add constraint "optr_pkey" primary key (company_code, "PymntRsnCd");
-- OSOIL: was (company_code, AbsEntry)
alter table sap."OSOIL" drop constraint "osoil_pkey", add constraint "osoil_pkey" primary key (company_code, "SOIWNum");
-- OUKD: was (company_code, KeyId)
alter table sap."OUKD" drop constraint "oukd_pkey", add constraint "oukd_pkey" primary key (company_code, "TableName", "KeyId");
-- PCH23: was (company_code, DocEntry, LineNum)
alter table sap."PCH23" drop constraint "pch23_pkey", add constraint "pch23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- PDN23: was (company_code, DocEntry, LineNum)
alter table sap."PDN23" drop constraint "pdn23_pkey", add constraint "pdn23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- PJT1: was (company_code, StepCode)
alter table sap."PJT1" drop constraint "pjt1_pkey", add constraint "pjt1_pkey" primary key (company_code, "DocEntry", "StepCode");
-- PKL1: was (company_code, AbsEntry)
alter table sap."PKL1" drop constraint "pkl1_pkey", add constraint "pkl1_pkey" primary key (company_code, "AbsEntry", "PickEntry");
-- PKL2: was (company_code, AbsEntry)
alter table sap."PKL2" drop constraint "pkl2_pkey", add constraint "pkl2_pkey" primary key (company_code, "AbsEntry", "PickEntry", "Pkl2LinNum");
-- POR23: was (company_code, DocEntry, LineNum)
alter table sap."POR23" drop constraint "por23_pkey", add constraint "por23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- PQT23: was (company_code, DocEntry, LineNum)
alter table sap."PQT23" drop constraint "pqt23_pkey", add constraint "pqt23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- PRQ23: was (company_code, DocEntry, LineNum)
alter table sap."PRQ23" drop constraint "prq23_pkey", add constraint "prq23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- PRR23: was (company_code, DocEntry, LineNum)
alter table sap."PRR23" drop constraint "prr23_pkey", add constraint "prr23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- QUT23: was (company_code, DocEntry, LineNum)
alter table sap."QUT23" drop constraint "qut23_pkey", add constraint "qut23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- RDN23: was (company_code, DocEntry, LineNum)
alter table sap."RDN23" drop constraint "rdn23_pkey", add constraint "rdn23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- RDR23: was (company_code, DocEntry, LineNum)
alter table sap."RDR23" drop constraint "rdr23_pkey", add constraint "rdr23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- RIN23: was (company_code, DocEntry, LineNum)
alter table sap."RIN23" drop constraint "rin23_pkey", add constraint "rin23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- RLD1: was (company_code, AbsEntry)
alter table sap."RLD1" drop constraint "rld1_pkey", add constraint "rld1_pkey" primary key (company_code, "AbsEntry", "TargetType", "TargetFld");
-- RPC23: was (company_code, DocEntry, LineNum)
alter table sap."RPC23" drop constraint "rpc23_pkey", add constraint "rpc23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- RPD23: was (company_code, DocEntry, LineNum)
alter table sap."RPD23" drop constraint "rpd23_pkey", add constraint "rpd23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- RRR23: was (company_code, DocEntry, LineNum)
alter table sap."RRR23" drop constraint "rrr23_pkey", add constraint "rrr23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- SEL1: was (company_code, AbsEntry)
alter table sap."SEL1" drop constraint "sel1_pkey", add constraint "sel1_pkey" primary key (company_code, "AbsEntry", "ObjID");
-- SFC23: was (company_code, DocEntry, LineNum)
alter table sap."SFC23" drop constraint "sfc23_pkey", add constraint "sfc23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- SFI23: was (company_code, DocEntry, LineNum)
alter table sap."SFI23" drop constraint "sfi23_pkey", add constraint "sfi23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- SVM1: was (company_code, AbsEntry)
alter table sap."SVM1" drop constraint "svm1_pkey", add constraint "svm1_pkey" primary key (company_code, "AbsEntry", "PropID");
-- SVM2: was (company_code, AbsEntry)
alter table sap."SVM2" drop constraint "svm2_pkey", add constraint "svm2_pkey" primary key (company_code, "AbsEntry", "ObjectId");
-- TPW2: was (company_code, AbsEntry)
alter table sap."TPW2" drop constraint "tpw2_pkey", add constraint "tpw2_pkey" primary key (company_code, "AbsEntry", "LineNumber");
-- TPW6: was (company_code, AbsEntry)
alter table sap."TPW6" drop constraint "tpw6_pkey", add constraint "tpw6_pkey" primary key (company_code, "AbsEntry", "JeId", "JeLineId");
-- TRB1: was (company_code, AbsEntry)
alter table sap."TRB1" drop constraint "trb1_pkey", add constraint "trb1_pkey" primary key (company_code, "AbsEntry", "State");
-- TRB2: was (company_code, AbsEntry)
alter table sap."TRB2" drop constraint "trb2_pkey", add constraint "trb2_pkey" primary key (company_code, "AbsEntry", "StaType");
-- TRB3: was (company_code, AbsEntry)
alter table sap."TRB3" drop constraint "trb3_pkey", add constraint "trb3_pkey" primary key (company_code, "AbsEntry", "NfTaxId");
-- TRB4: was (company_code, AbsEntry)
alter table sap."TRB4" drop constraint "trb4_pkey", add constraint "trb4_pkey" primary key (company_code, "AbsEntry", "TaxSrcType", "TaxEntry", "TaxLine");
-- TRB5: was (company_code, AbsEntry)
alter table sap."TRB5" drop constraint "trb5_pkey", add constraint "trb5_pkey" primary key (company_code, "AbsEntry", "State");
-- UGP1: was (company_code, UgpEntry, UomEntry)
alter table sap."UGP1" drop constraint "ugp1_pkey", add constraint "ugp1_pkey" primary key (company_code, "UgpEntry", "LineNum");
-- VLG1: was (company_code, AbsEntry)
alter table sap."VLG1" drop constraint "vlg1_pkey", add constraint "vlg1_pkey" primary key (company_code, "AbsEntry", "RecNum");
-- VRW1: was (company_code, AbsEntry)
alter table sap."VRW1" drop constraint "vrw1_pkey", add constraint "vrw1_pkey" primary key (company_code, "AbsEntry", "VatGroup");
-- VRW2: was (company_code, AbsEntry)
alter table sap."VRW2" drop constraint "vrw2_pkey", add constraint "vrw2_pkey" primary key (company_code, "AbsEntry", "TaxInvID", "VatGroup", "ARINVAbs");
-- VRW3: was (company_code, AbsEntry)
alter table sap."VRW3" drop constraint "vrw3_pkey", add constraint "vrw3_pkey" primary key (company_code, "AbsEntry", "CardCode");
-- VRW4: was (company_code, AbsEntry)
alter table sap."VRW4" drop constraint "vrw4_pkey", add constraint "vrw4_pkey" primary key (company_code, "AbsEntry", "BPLId");
-- VTR1: was (company_code, AbsEntry)
alter table sap."VTR1" drop constraint "vtr1_pkey", add constraint "vtr1_pkey" primary key (company_code, "AbsEntry", "ObjectCode", "Adtnl_Key");
-- VTR2: was (company_code, AbsEntry)
alter table sap."VTR2" drop constraint "vtr2_pkey", add constraint "vtr2_pkey" primary key (company_code, "AbsEntry", "ObjectCode");
-- VTR3: was (company_code, AbsEntry)
alter table sap."VTR3" drop constraint "vtr3_pkey", add constraint "vtr3_pkey" primary key (company_code, "AbsEntry", "SeriesCode", "ObjectCode");
-- WTQ23: was (company_code, DocEntry, LineNum)
alter table sap."WTQ23" drop constraint "wtq23_pkey", add constraint "wtq23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
-- WTR23: was (company_code, DocEntry, LineNum)
alter table sap."WTR23" drop constraint "wtr23_pkey", add constraint "wtr23_pkey" primary key (company_code, "DocEntry", "LineNum", "VisOrder");
