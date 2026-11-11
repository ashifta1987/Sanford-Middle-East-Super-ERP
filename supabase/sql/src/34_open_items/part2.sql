
-- ============ 4. Landed costs in a foreign currency ============
-- A charge line may be in another currency than the company's: its rate is fx_rate_list on the landed cost date (only
-- Financials may type another one, as on documents). The split and the posting are in LC; the FC amount and the rate are kept.
-- A charge may name the broker's / forwarder's A/P invoice that bills it (same currency). The clearing account is then
-- credited at that invoice's own LC value, so it clears exactly what the invoice debited; the difference to the LC that was
-- capitalised is a rate difference (purchasing / fx_loss, sales / fx_gain), as B4 does for an A/P invoice against its GRPO.
-- The value split of a goods receipt in a foreign currency now uses the receipt's LC value (B4 used the price in its currency).
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS currency varchar(3);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS amount_fc numeric(19,2);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS fx_rate numeric(19,6);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS ap_invoice_entry integer;
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS clear_amount numeric(19,2);
ALTER TABLE erp.landed_cost_charge ADD COLUMN IF NOT EXISTS fx_diff numeric(19,2);
CREATE INDEX IF NOT EXISTS landed_cost_charge_ap_idx ON erp.landed_cost_charge (company_code, ap_invoice_entry) WHERE ap_invoice_entry IS NOT NULL;
