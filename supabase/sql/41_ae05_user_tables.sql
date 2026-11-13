-- 41 · AE05 user-defined tables (14 Nov 2026): @-tables with rows in SAP (row_counts.csv) that had no table in the sap
-- schema, so the 13 Nov load skipped them. Generated from the AE05 export create.sql; conventions as 01b_addon_udt.sql.
-- Only key columns are NOT NULL (user-defined fields differ per company). New tables only - nothing existing changes.
BEGIN;
-- @AIOU  (25 columns, 4 rows in SAP for AE05; key: DocEntry, LogInst)
CREATE TABLE IF NOT EXISTS sap."@AIOU" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "DocEntry" integer NOT NULL,
    "DocNum" integer,
    "Period" integer,
    "Instance" smallint,
    "Series" integer,
    "Handwrtten" varchar(1),
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer NOT NULL,
    "UserSign" integer,
    "Transfered" varchar(1),
    "Status" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "RequestStatus" varchar(1),
    "Creator" varchar(25),
    "Remark" text,
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_ApprovedBy" varchar(10),
    "U_Date" timestamp,
    CONSTRAINT "aiou_pkey" PRIMARY KEY ("company_code", "DocEntry", "LogInst")
);
ALTER TABLE sap."@AIOU" ENABLE ROW LEVEL SECURITY;
-- @AIOU_LINE  (9 columns, 4 rows in SAP for AE05; key: DocEntry, LineId, LogInst)
CREATE TABLE IF NOT EXISTS sap."@AIOU_LINE" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "DocEntry" integer NOT NULL,
    "LineId" integer NOT NULL,
    "VisOrder" integer,
    "Object" varchar(20),
    "LogInst" integer NOT NULL,
    "EncryptIV" varchar(100),
    "U_Remarks" varchar(200),
    "U_PaidTo" varchar(30),
    "U_Amount" numeric(21,6),
    CONSTRAINT "aiou_line_pkey" PRIMARY KEY ("company_code", "DocEntry", "LineId", "LogInst")
);
ALTER TABLE sap."@AIOU_LINE" ENABLE ROW LEVEL SECURITY;
-- @COMPLAINT_REGISTER  (23 columns, 11630 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@COMPLAINT_REGISTER" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_ItemCode" varchar(50),
    "U_ItemDesc" varchar(150),
    "U_Quantity" numeric(21,6),
    "U_Region" varchar(20),
    "U_YearMonth" varchar(6),
    "U_CreDate" timestamp,
    "U_ComplaintType" varchar(150),
    CONSTRAINT "complaint_register_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@COMPLAINT_REGISTER" ENABLE ROW LEVEL SECURITY;
-- @CTX_EXCHANGELIST  (5 columns, 11 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@CTX_EXCHANGELIST" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_CTX_OBJECT" varchar(100),
    "U_CTX_DOCNAME" varchar(200),
    "U_CTX_DOCFRM" varchar(1),
    CONSTRAINT "ctx_exchangelist_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@CTX_EXCHANGELIST" ENABLE ROW LEVEL SECURITY;
-- @DISPLAY_RENT_LINES  (7 columns, 148 rows in SAP for AE05; key: Code, LineId)
CREATE TABLE IF NOT EXISTS sap."@DISPLAY_RENT_LINES" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "LineId" integer NOT NULL,
    "Object" varchar(20),
    "LogInst" integer,
    "EncryptIV" varchar(100),
    "U_Sale" numeric(21,6),
    "U_Display_Rent" numeric(21,6),
    CONSTRAINT "display_rent_lines_pkey" PRIMARY KEY ("company_code", "Code", "LineId")
);
ALTER TABLE sap."@DISPLAY_RENT_LINES" ENABLE ROW LEVEL SECURITY;
-- @DISPLAY_RENT_MASTER  (16 columns, 37 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@DISPLAY_RENT_MASTER" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    CONSTRAINT "display_rent_master_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@DISPLAY_RENT_MASTER" ENABLE ROW LEVEL SECURITY;
-- @IOU  (25 columns, 2 rows in SAP for AE05; key: DocEntry)
CREATE TABLE IF NOT EXISTS sap."@IOU" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "DocEntry" integer NOT NULL,
    "DocNum" integer,
    "Period" integer,
    "Instance" smallint,
    "Series" integer,
    "Handwrtten" varchar(1),
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "Status" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "RequestStatus" varchar(1),
    "Creator" varchar(25),
    "Remark" text,
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_ApprovedBy" varchar(10),
    "U_Date" timestamp,
    CONSTRAINT "iou_pkey" PRIMARY KEY ("company_code", "DocEntry")
);
ALTER TABLE sap."@IOU" ENABLE ROW LEVEL SECURITY;
-- @IOU_LINE  (9 columns, 2 rows in SAP for AE05; key: DocEntry, LineId)
CREATE TABLE IF NOT EXISTS sap."@IOU_LINE" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "DocEntry" integer NOT NULL,
    "LineId" integer NOT NULL,
    "VisOrder" integer,
    "Object" varchar(20),
    "LogInst" integer,
    "EncryptIV" varchar(100),
    "U_Remarks" varchar(200),
    "U_PaidTo" varchar(30),
    "U_Amount" numeric(21,6),
    CONSTRAINT "iou_line_pkey" PRIMARY KEY ("company_code", "DocEntry", "LineId")
);
ALTER TABLE sap."@IOU_LINE" ENABLE ROW LEVEL SECURITY;
-- @LISTED_ITEMS  (18 columns, 1 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@LISTED_ITEMS" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_ItemCode" varchar(50),
    "U_ItemDescription" varchar(75),
    CONSTRAINT "listed_items_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@LISTED_ITEMS" ENABLE ROW LEVEL SECURITY;
-- @MERCHANDISER_MASTER  (30 columns, 245 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@MERCHANDISER_MASTER" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_SLPCode" integer,
    "U_Status" varchar(10),
    "U_Executive_Contact_Number" varchar(10),
    "U_Supervisor_Name" varchar(30),
    "U_Supervisor_Contact_Number" varchar(10),
    "U_Outlet_Joining_Date" timestamp,
    "U_Merchandiser_Joining_Date" timestamp,
    "U_Purchaser_Name" varchar(20),
    "U_Card_Code" varchar(20),
    "U_Purchaser_Contact_Number" varchar(10),
    "U_Merchandiser_Contact_Number" varchar(10),
    "U_Outlet_Name" varchar(10),
    "U_Grp_No" integer,
    "U_Grp_Sl_No" integer,
    CONSTRAINT "merchandiser_master_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@MERCHANDISER_MASTER" ENABLE ROW LEVEL SECURITY;
-- @MONTHLY_TARGET  (20 columns, 71 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@MONTHLY_TARGET" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_Month" timestamp,
    "U_Target" numeric(21,6),
    "U_CCode" varchar(15),
    "U_ItemCode" varchar(50),
    CONSTRAINT "monthly_target_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@MONTHLY_TARGET" ENABLE ROW LEVEL SECURITY;
-- @OE_APPMAPPING  (5 columns, 36 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_APPMAPPING" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_USERID" integer,
    "U_OE_INFO1" varchar(1),
    CONSTRAINT "oe_appmapping_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_APPMAPPING" ENABLE ROW LEVEL SECURITY;
-- @OE_CROSSREF_MASTER  (8 columns, 11 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_CROSSREF_MASTER" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_OBJECTID" varchar(20),
    "U_OE_OBJECTNAME" varchar(254),
    "U_OE_CROSSREFID" varchar(254),
    "U_OE_CROSSREFNAME" varchar(254),
    CONSTRAINT "oe_crossref_master_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_CROSSREF_MASTER" ENABLE ROW LEVEL SECURITY;
-- @OE_FETRACTLNCS  (11 columns, 26 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_FETRACTLNCS" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_ACTV" varchar(254),
    "U_OE_SCRX" varchar(1),
    "U_OE_LCHK" varchar(254),
    "U_OE_TSDT" varchar(254),
    "U_OE_TEDT" varchar(254),
    "U_OE_Info" varchar(254),
    "U_OE_COUNT" varchar(100),
    "U_OE_COUNTF" varchar(100),
    CONSTRAINT "oe_fetractlncs_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_FETRACTLNCS" ENABLE ROW LEVEL SECURITY;
-- @OE_GENERAL_SETTINGS  (8 columns, 21 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_GENERAL_SETTINGS" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_SETTINGID" varchar(20),
    "U_OE_SETTINGNAME" varchar(254),
    "U_OE_SETTINGVALUEID" varchar(254),
    "U_OE_SETTINGVALUENAME" varchar(254),
    CONSTRAINT "oe_general_settings_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_GENERAL_SETTINGS" ENABLE ROW LEVEL SECURITY;
-- @OE_GN_ITEM  (12 columns, 706 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_GN_ITEM" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_CRFC" varchar(254),
    "U_OE_SYNC" varchar(1),
    "U_OE_TPID" varchar(254),
    "U_OE_PTYPE" varchar(254),
    "U_OE_COIT" varchar(254),
    "U_OE_ICODE" varchar(254),
    "U_OE_VITM" varchar(100),
    "U_OE_INVITM" varchar(254),
    CONSTRAINT "oe_gn_item_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_GN_ITEM" ENABLE ROW LEVEL SECURITY;
-- @OE_HUBSYS  (7 columns, 1 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_HUBSYS" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_B1SERVER" varchar(254),
    "U_OE_SLDCAT" varchar(254),
    "U_OE_COMPDB" varchar(254),
    "U_OE_SYSID" varchar(254),
    "U_OE_DBTYPE" varchar(254),
    CONSTRAINT "oe_hubsys_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_HUBSYS" ENABLE ROW LEVEL SECURITY;
-- @OE_HUBTEMPLATES  (8 columns, 1 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_HUBTEMPLATES" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_TEMPNAME" varchar(60),
    "U_OE_ACTIVE" varchar(1),
    "U_OE_SCRX" varchar(254),
    "U_OE_ARCHIVED" varchar(1),
    CONSTRAINT "oe_hubtemplates_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_HUBTEMPLATES" ENABLE ROW LEVEL SECURITY;
-- @OE_NOTIFICATION  (12 columns, 8 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_NOTIFICATION" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_USERID" varchar(50),
    "U_OE_USERNAME" varchar(254),
    "U_OE_OBJECTID" varchar(100),
    "U_OE_OBJECTNAME" varchar(254),
    "U_OE_SENDALERT" varchar(1),
    "U_OE_LangCode" varchar(100),
    "U_OE_EmailAlert" varchar(1),
    "U_OE_EmailFail" varchar(1),
    CONSTRAINT "oe_notification_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_NOTIFICATION" ENABLE ROW LEVEL SECURITY;
-- @OE_OBJECTMAPPING  (12 columns, 13 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_OBJECTMAPPING" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_OBJECTID" varchar(20),
    "U_OE_SBORECID" varchar(254),
    "U_OE_SBORECNAME" varchar(254),
    "U_OE_CROSSREFID" varchar(254),
    "U_OE_CROSSREFNAME" varchar(254),
    "U_OE_ISDEFAULT" varchar(1),
    "U_OE_SYNC" varchar(1),
    "U_OE_DEFAULTLIST" varchar(254),
    CONSTRAINT "oe_objectmapping_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_OBJECTMAPPING" ENABLE ROW LEVEL SECURITY;
-- @OE_SYNCHRONIZATION  (10 columns, 4 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_SYNCHRONIZATION" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_OBJECTID" varchar(20),
    "U_OE_OBJECTNAME" varchar(254),
    "U_OE_RUNON" integer,
    "U_OE_RUNONDAY" integer,
    "U_OE_RUNATHOUR" integer,
    "U_OE_RUNATMINUTE" integer,
    CONSTRAINT "oe_synchronization_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_SYNCHRONIZATION" ENABLE ROW LEVEL SECURITY;
-- @OE_TEMPOBJMAP  (8 columns, 9 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_TEMPOBJMAP" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_APPID" integer,
    "U_OE_TEMPLATEID" integer,
    "U_OE_OBJECTID" varchar(100),
    "U_OE_SUPPORTED" varchar(1),
    "U_OE_SYNC" varchar(1),
    "U_OE_APP_SYNC" varchar(1),
    CONSTRAINT "oe_tempobjmap_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_TEMPOBJMAP" ENABLE ROW LEVEL SECURITY;
-- @OE_USERINFO  (5 columns, 51 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OE_USERINFO" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "U_OE_USERCODE" varchar(254),
    "U_OE_COUNT" varchar(254),
    "U_OE_DATE" varchar(50),
    CONSTRAINT "oe_userinfo_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OE_USERINFO" ENABLE ROW LEVEL SECURITY;
-- @OUTLET_AGEING  (23 columns, 65 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OUTLET_AGEING" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_Itemcode" varchar(20),
    "U_Barcode" varchar(20),
    "U_Last_Billing_Date" timestamp,
    "U_Last_Billing_Quantity" integer,
    "U_Ageing_Quantity" integer,
    "U_Ageing_Value" integer,
    "U_New_Billing_Price" integer,
    CONSTRAINT "outlet_ageing_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OUTLET_AGEING" ENABLE ROW LEVEL SECURITY;
-- @OUTLET_SALES  (22 columns, 35 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OUTLET_SALES" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_Card_Code" varchar(20),
    "U_Item_Code" varchar(20),
    "U_From_Date" timestamp,
    "U_To_Date" timestamp,
    "U_Sold_Quantity" integer,
    "U_Sold_Value" numeric(21,6),
    CONSTRAINT "outlet_sales_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OUTLET_SALES" ENABLE ROW LEVEL SECURITY;
-- @OUTLET_STOCK  (20 columns, 96 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@OUTLET_STOCK" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_Itemcode" varchar(25),
    "U_Customer_Code" varchar(20),
    "U_Stock_Qty" integer,
    "U_StockAsOn" timestamp,
    CONSTRAINT "outlet_stock_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@OUTLET_STOCK" ENABLE ROW LEVEL SECURITY;
-- @PRODUCTTARGET  (23 columns, 10 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@PRODUCTTARGET" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_Date" timestamp,
    "U_KSA" numeric(21,6),
    "U_UAE" numeric(21,6),
    "U_KUWAIT" numeric(21,6),
    "U_OMAN" numeric(21,6),
    "U_BAHRAIN" numeric(21,6),
    "U_QATAR" numeric(21,6),
    CONSTRAINT "producttarget_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@PRODUCTTARGET" ENABLE ROW LEVEL SECURITY;
-- @RECEIPTBOOK  (16 columns, 68 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@RECEIPTBOOK" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    CONSTRAINT "receiptbook_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@RECEIPTBOOK" ENABLE ROW LEVEL SECURITY;
-- @RECEIPTSLIP  (7 columns, 3400 rows in SAP for AE05; key: Code, LineId)
CREATE TABLE IF NOT EXISTS sap."@RECEIPTSLIP" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "LineId" integer NOT NULL,
    "Object" varchar(20),
    "LogInst" integer,
    "EncryptIV" varchar(100),
    "U_SlipNumber" integer,
    "U_Status" varchar(10),
    CONSTRAINT "receiptslip_pkey" PRIMARY KEY ("company_code", "Code", "LineId")
);
ALTER TABLE sap."@RECEIPTSLIP" ENABLE ROW LEVEL SECURITY;
-- @SALES_TARGET  (21 columns, 11766 rows in SAP for AE05; key: Code)
CREATE TABLE IF NOT EXISTS sap."@SALES_TARGET" (
    "company_code" varchar(8) NOT NULL DEFAULT current_setting('sap.company', true),
    "Code" varchar(50) NOT NULL,
    "Name" varchar(100),
    "DocEntry" integer,
    "Canceled" varchar(1),
    "Object" varchar(20),
    "LogInst" integer,
    "UserSign" integer,
    "Transfered" varchar(1),
    "CreateDate" timestamp,
    "CreateTime" smallint,
    "UpdateDate" timestamp,
    "UpdateTime" smallint,
    "DataSource" varchar(1),
    "NaturalPer" varchar(1),
    "DPPStatus" varchar(1),
    "EncryptIV" varchar(100),
    "U_From_Date" timestamp,
    "U_To_Date" timestamp,
    "U_C_Code" varchar(10),
    "U_Target" numeric(21,6),
    "U_Conso_Bp_Collection" varchar(1),
    CONSTRAINT "sales_target_pkey" PRIMARY KEY ("company_code", "Code")
);
ALTER TABLE sap."@SALES_TARGET" ENABLE ROW LEVEL SECURITY;
COMMIT;
