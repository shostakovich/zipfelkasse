-- Older templates carry date and recurring_id, "" for no rate source and 0 for no category.
UPDATE recurring SET template_json = json_remove(template_json, '$.date', '$.recurring_id');
UPDATE recurring SET template_json = json_remove(template_json, '$.fx_source')
  WHERE json_extract(template_json, '$.fx_source') = '';
UPDATE recurring SET template_json = json_remove(template_json, '$.category_id')
  WHERE json_extract(template_json, '$.category_id') = 0;
DELETE FROM settings WHERE key = 'fx.ezb_hist_bis';
