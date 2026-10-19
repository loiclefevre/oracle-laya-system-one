-- Load LAYA_TEXT_INT8_SHARED model and install laya_text_scorer.sql first.
-- Temperature 1 means uncalibrated softmax; substitute your validated value.

-- should return "Yes"
SELECT laya_text_scorer.predict(
  p_mode => 'noul',
  p_context => 'My credit card was charged 2 times for my subscription.',
  p_question => 'Was the customer charged twice?'
) AS result;

-- should return "billing"
SELECT laya_text_scorer.predict(
  p_mode => 'choice',
  p_context => 'The customer reports being charged twice.',
  p_question => 'Which team should handle this?',
  p_choices_json => json ['billing','technical'],
  p_temperature => 1
) AS result;

-- should return "medium"
SELECT laya_text_scorer.predict(
  p_mode => 'score',
  p_context => 'The test database is unavailable to one developer.',
  p_question => 'How severe is this incident?',
  p_choices_json => json['low','medium','high','critical']
) AS result FROM dual;
