-- Install after loading LAYA_TEXT_INT8_SHARED.
CREATE OR REPLACE PACKAGE laya_text_scorer AUTHID CURRENT_USER AS
  FUNCTION format_request(p_mode VARCHAR2, p_context VARCHAR2, p_question VARCHAR2,
    p_choices_json json DEFAULT NULL) RETURN VARCHAR2;
  FUNCTION evaluate(p_mode VARCHAR2, p_output VECTOR,
    p_choices_json json DEFAULT NULL, p_temperature NUMBER DEFAULT 1) RETURN JSON;
  FUNCTION predict(p_mode VARCHAR2, p_context VARCHAR2, p_question VARCHAR2,
    p_choices_json json DEFAULT NULL, p_temperature NUMBER DEFAULT 1) RETURN JSON;
END laya_text_scorer;
/

CREATE OR REPLACE PACKAGE BODY laya_text_scorer AS
  TYPE numbers_t IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  FUNCTION mode_name(p_mode VARCHAR2) RETURN VARCHAR2 IS
    m VARCHAR2(32767) := LOWER(TRIM(p_mode));
  BEGIN
    IF m IS NULL OR m NOT IN ('noul','choice','score') THEN
      RAISE_APPLICATION_ERROR(-20301, 'Mode must be noul, choice or score.');
    END IF;
    RETURN p_mode;
  END;

  FUNCTION options(p_mode VARCHAR2, p_choices json) RETURN JSON_ARRAY_T IS
    a JSON_ARRAY_T;
    e JSON_ELEMENT_T;
    s VARCHAR2(32767);
  BEGIN
    IF p_mode = 'noul' THEN
      RETURN JSON_ARRAY_T.parse('["false","true"]');
    END IF;
    IF p_choices IS NULL THEN
      RAISE_APPLICATION_ERROR(-20302, 'Provide an ordered JSON array of option strings.');
    END IF;
    e := JSON_ELEMENT_T.load(p_choices);
    IF NOT e.IS_ARRAY() THEN
      RAISE_APPLICATION_ERROR(-20302, 'Choices must be an ordered JSON string array.');
    END IF;
    a := TREAT(e AS JSON_ARRAY_T);
    IF a.GET_SIZE() < 2 OR a.GET_SIZE() > 32 THEN
      RAISE_APPLICATION_ERROR(-20302, 'Provide 2..32 options.');
    END IF;
    FOR i IN 0..a.GET_SIZE()-1 LOOP
      e := a.GET(i);
      IF NOT e.IS_STRING() THEN
        RAISE_APPLICATION_ERROR(-20302, 'Every option must be a nonempty string.');
      END IF;
      s := a.GET_STRING(i);
      IF TRIM(s) IS NULL OR LENGTH(s) > 4000 THEN
        RAISE_APPLICATION_ERROR(-20302, 'Options must contain 1..4000 characters.');
      END IF;
      IF i > 0 THEN
        FOR j IN 0..i-1 LOOP
          IF a.GET_STRING(j) = s THEN
            RAISE_APPLICATION_ERROR(-20302, 'Duplicate option strings are not supported.');
          END IF;
        END LOOP;
      END IF;
    END LOOP;
    RETURN a;
  END;

  PROCEDURE check_text(s VARCHAR2) IS
  BEGIN
    IF INSTR(s,'[CLS]') > 0 OR INSTR(s,'[SEP]') > 0 OR
       INSTR(s,'[MASK]') > 0 OR INSTR(s,'[PAD]') > 0 OR INSTR(s,'[UNK]') > 0 THEN
      RAISE_APPLICATION_ERROR(-20303, 'User content must not contain reserved tokenizer tokens.');
    END IF;
  END;

  FUNCTION format_request(p_mode VARCHAR2, p_context VARCHAR2, p_question VARCHAR2,
    p_choices_json json DEFAULT NULL) RETURN VARCHAR2 IS
    m VARCHAR2(10) := mode_name(p_mode);
    a JSON_ARRAY_T := options(m, p_choices_json);
    s VARCHAR2(32767);
    rendered VARCHAR2(32767);
  BEGIN
    IF TRIM(p_question) IS NULL THEN
      RAISE_APPLICATION_ERROR(-20303, 'Question is required.');
    END IF;
    check_text(p_question);
    check_text(p_context);
    s := CASE m WHEN 'choice' THEN '0' WHEN 'score' THEN '1' ELSE '2' END ||
      '[CLS]' || m || ' question: ' || p_question || '[SEP]';
    IF m = 'noul' THEN
      s := s || '[MASK] false: no, the statement does not hold' ||
                '[MASK] true: yes, the statement holds';
    ELSE
      FOR i IN 0..a.GET_SIZE()-1 LOOP
        rendered := a.GET_STRING(i);
        check_text(rendered);
        IF m = 'score' THEN
          rendered := 'level ' || TO_CHAR(i, 'FM990') || ': ' || rendered;
        END IF;
        s := s || '[MASK] ' || rendered;
      END LOOP;
    END IF;
    s := s || '[SEP]' || p_context || '[SEP]';
    -- Conservative SQL VARCHAR2 limit; no implicit truncation.
    IF LENGTHB(s) > 4000 THEN
      RAISE_APPLICATION_ERROR(-20304, 'Formatted request exceeds 4000 bytes; shorten the input.');
    END IF;
    RETURN s;
  EXCEPTION
    WHEN VALUE_ERROR THEN
      RAISE_APPLICATION_ERROR(-20304, 'Formatted request is too long.');
  END;

  FUNCTION evaluate(p_mode VARCHAR2, p_output VECTOR,
    p_choices_json json DEFAULT NULL, p_temperature NUMBER DEFAULT 1) RETURN JSON IS
    m VARCHAR2(10) := mode_name(p_mode);
    a JSON_ARRAY_T := options(m, p_choices_json);
    serialized CLOB;
    v JSON_ARRAY_T;
    e JSON_ELEMENT_T;
    z numbers_t;
    probs numbers_t;
    k PLS_INTEGER := a.GET_SIZE();
    best PLS_INTEGER := 0;
    max_z NUMBER;
    sum_exp NUMBER := 0;
    entropy NUMBER := 0;
    expected_score NUMBER := 0;
    concentration NUMBER;
    action_max NUMBER;
    action0 NUMBER;
    action1 NUMBER;
    l_result JSON_OBJECT_T := JSON_OBJECT_T();
    distribution JSON_ARRAY_T := JSON_ARRAY_T();
    entry JSON_OBJECT_T;
    action JSON_OBJECT_T := JSON_OBJECT_T();
    action_probs JSON_ARRAY_T := JSON_ARRAY_T();
    decision VARCHAR2(4000);
  BEGIN
    IF p_output IS NULL OR p_temperature IS NULL OR p_temperature <= 0 THEN
      RAISE_APPLICATION_ERROR(-20305, 'Output is required and temperature must be positive.');
    END IF;
    SELECT VECTOR_SERIALIZE(p_output RETURNING CLOB) INTO serialized FROM dual;
    v := JSON_ARRAY_T.PARSE(serialized);
    IF v.GET_SIZE() != 36 THEN
      RAISE_APPLICATION_ERROR(-20306, 'Expected the default 36-entry decision_vector.');
    END IF;
    FOR i IN 0..35 LOOP
      e := v.GET(i);
      IF NOT e.IS_NUMBER() OR v.GET_NUMBER(i) IS NULL THEN
        RAISE_APPLICATION_ERROR(-20306, 'Output contains a nonnumeric/nonfinite entry.');
      END IF;
    END LOOP;
    IF v.GET_NUMBER(0) != 1 THEN
      RAISE_APPLICATION_ERROR(-20307, 'Model rejected request structure or token/marker capacity.');
    END IF;
    IF v.GET_NUMBER(1) != k THEN
      RAISE_APPLICATION_ERROR(-20307, 'Model answer count does not match supplied options.');
    END IF;
    max_z := v.GET_NUMBER(2);
    FOR i IN 0..k-1 LOOP
      z(i) := v.GET_NUMBER(i+2);
      IF z(i) > max_z THEN max_z := z(i); best := i; END IF;
    END LOOP;
    FOR i IN 0..k-1 LOOP
      -- Avoid underflow in Oracle NUMBER; negligible tails become zero.
      IF (z(i)-max_z)/p_temperature < -250 THEN probs(i) := 0;
      ELSE probs(i) := EXP((z(i)-max_z)/p_temperature); END IF;
      sum_exp := sum_exp + probs(i);
    END LOOP;
    FOR i IN 0..k-1 LOOP
      probs(i) := probs(i)/sum_exp;
      IF probs(i) > 0 THEN entropy := entropy - probs(i)*LN(GREATEST(probs(i),1e-12)); END IF;
      expected_score := expected_score + i*probs(i);
      entry := JSON_OBJECT_T();
      entry.PUT('index', i);
      entry.PUT('label', a.GET_STRING(i));
      entry.PUT('probability', probs(i));
      distribution.APPEND(entry);
    END LOOP;
    concentration := GREATEST(0, LEAST(1, 1 - entropy/LN(k)));
    -- Noul ties resolve to Yes, consistent with the earlier CLM-style interface.
    IF m = 'noul' AND probs(1) >= 0.5 THEN best := 1; END IF;
    decision := a.GET_STRING(best);
    l_result.PUT('type', m);
    l_result.PUT('selected_index', best);
    l_result.PUT('selected', decision);
    l_result.PUT('probabilities', distribution);
    l_result.PUT('probability', probs(best));
    l_result.PUT('answer_confidence', probs(best));
    l_result.PUT('entropy_confidence', concentration);
    l_result.PUT('temperature', p_temperature);
    IF m = 'noul' THEN
      l_result.PUT('decision', CASE best WHEN 1 THEN 'Yes' ELSE 'No' END);
      l_result.PUT('noul', probs(1));
      l_result.PUT('confidence', probs(best));
    ELSIF m = 'choice' THEN
      l_result.PUT('decision', decision);
      l_result.PUT('choice', decision);
      l_result.PUT('confidence', concentration);
    ELSE
      l_result.PUT('decision', decision);
      l_result.PUT('score', expected_score);
      l_result.PUT('normalized_score', expected_score/(k-1));
      l_result.PUT('level', decision);
      l_result.PUT('level_index', best);
      l_result.PUT('confidence', concentration);
    END IF;
    action_max := GREATEST(v.GET_NUMBER(34), v.GET_NUMBER(35));
    action0 := EXP(GREATEST(-250, v.GET_NUMBER(34)-action_max));
    action1 := EXP(GREATEST(-250, v.GET_NUMBER(35)-action_max));
    action_probs.APPEND(action0/(action0+action1));
    action_probs.APPEND(action1/(action0+action1));
    action.PUT('probabilities', action_probs);
    action.PUT('act_probability', action0/(action0+action1));
    l_result.PUT('action', action);
    RETURN l_result.TO_JSON();
  END;

  FUNCTION predict(p_mode VARCHAR2, p_context VARCHAR2, p_question VARCHAR2,
    p_choices_json json DEFAULT NULL, p_temperature NUMBER DEFAULT 1) RETURN JSON IS
    request VARCHAR2(32767);
    output VECTOR;
  BEGIN
    IF p_temperature IS NULL OR p_temperature <= 0 THEN
      RAISE_APPLICATION_ERROR(-20305, 'Temperature must be positive.');
    END IF;
    request := format_request(p_mode, p_context, p_question, p_choices_json);
    SELECT VECTOR_EMBEDDING(LAYA_TEXT_INT8_SHARED USING request AS DATA) INTO output;
    RETURN evaluate(p_mode, output, p_choices_json, p_temperature);
  END;
END laya_text_scorer;
/
SHOW ERRORS PACKAGE laya_text_scorer
SHOW ERRORS PACKAGE BODY laya_text_scorer
