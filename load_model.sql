create or replace directory ONNX_DIR as '/opt/oracle';

begin
  begin
    -- drop if exists
    DBMS_VECTOR.DROP_ONNX_MODEL('LAYA_TEXT_INT8_SHARED');
  exception when others then null;
  end;
  DBMS_VECTOR.LOAD_ONNX_MODEL(
    directory => 'ONNX_DIR',
    file_name => 'laya_text_int8_shared.onnx',
    model_name => 'LAYA_TEXT_INT8_SHARED',
    metadata => json('{"function":"embedding","embeddingOutput":"decision_vector","input":{"request":["DATA"]}}'),
    external_data_file_name => 'laya_text_int8_shared_external_data.json'
  );
end;
/

-- Enable In-Memory loading
begin
  DBMS_VECTOR.INMEMORY_ONNX_MODEL('LAYA_TEXT_INT8_SHARED', TRUE);
end;
/

-- Check
SELECT *
  FROM user_mining_models
 WHERE model_name = 'LAYA_TEXT_INT8_SHARED';
