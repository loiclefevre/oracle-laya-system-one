# Laya System One within Oracle AI Database 26ai FREE

## Installation

- unzip the zipped ONNX model data file
- start a 26ai free container with 5 GB shared memory (`--shm-size 5G`)
```bash
wslc run -d --shm-size 5G --name myclm -p 1521:1521 -e ORACLE_PASSWORD=free -e APP_USER=developer -e APP_USER_PASSWORD=free gvenzl/oracle-free:23.26.3-full 
```
- copy the files `laya_text_int8_shared.onnx`, `laya_text_int8_shared_external_data.json`, and `laya_text_int8_shared.data` (once unzipped) into the container under `/opt/oracle`
- connect as developer/free and load the model using `load_model.sql`
- install the PL/SQL package `laya_text_scorer.sql`
- run some tests using `examples.sql`
- 