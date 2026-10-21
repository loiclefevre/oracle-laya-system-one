-- as sys or system, connected to freepdb1 PDB
sqlplus / as sysdba
alter session set container=freepdb1;
create or replace directory ONNX_DIR as '/opt/oracle';
grant read, write on directory ONNX_DIR to developer;

-- as developer user
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
-- to avoid: https://docs.oracle.com/en/error-help/db/ora-54484/?r=26ai
-- as sys in CDB$ROOT
alter system set pga_aggregate_limit=5G scope=spfile;
alter system set "_dmm_shared_memory_size"=5G scope=spfile;
-- as sys in freepdb1 PDB
alter session set container=freepdb1;
alter system set "_dmm_shared_memory_size"=5G scope=spfile;

-- restart the database

-- as developer user
begin
  DBMS_VECTOR.INMEMORY_ONNX_MODEL('LAYA_TEXT_INT8_SHARED', TRUE);
end;
/

-- Check, YES should appear in both columns
SELECT external_data, inmemory
  FROM user_mining_models
 WHERE model_name = 'LAYA_TEXT_INT8_SHARED';
