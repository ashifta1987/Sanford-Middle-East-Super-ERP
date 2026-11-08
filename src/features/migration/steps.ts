/** Plain names for the worker's step codes (P4). */
export const STEP_NAMES: Record<string, { name: string; desc: string }> = {
  validate: { name: 'Check the files', desc: 'Unpack, classify files, read the field list' },
  stage: { name: 'Read the data files', desc: 'Every table copied to temporary tables first' },
  cast: { name: 'Copy into the SAP copy', desc: "This company's rows replaced table by table" },
  clean_02: { name: 'Clean blank links', desc: 'Blank text links and SAP -1 values become empty' },
  orphans_03: { name: 'Look for broken links', desc: 'Rows pointing at something missing' },
  links_04: { name: 'Add table links', desc: 'Links and indexes added and validated' },
  real_keys: { name: "Use SAP's real keys", desc: "Compare SAP's keys with ours" },
  security_06: { name: 'Lock the SAP copy', desc: 'Raw layer stays hidden from the app' },
  app_sync: { name: 'Fill the app tables', desc: 'The 83 sync steps, in one transaction' },
  check_sync: { name: 'App checks', desc: 'App tables against the SAP copy' },
  check_deleted: { name: 'Deleted in SAP', desc: 'App rows no longer in SAP' },
  cross_check: { name: 'Cross-check the whole system', desc: 'Counts, links, finance, stock, HR' },
};

