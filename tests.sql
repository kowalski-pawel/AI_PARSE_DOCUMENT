-- AI_PARSE_DOCUMENT: OCR vs LAYOUT vs AGENTIC
-- Input file: agentic_test.pdf (generate_test_doc.py)

CREATE DATABASE IF NOT EXISTS AI_PARSE_TEST;
CREATE STAGE IF NOT EXISTS AI_PARSE_TEST.PUBLIC.DOCS
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
-- PUT 'file://c:/nauka/Snowflake/Artykuły/07_AI_PARSE_DOCUMENT/agentic_test.pdf' @AI_PARSE_TEST.PUBLIC.DOCS AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Parse once and store the results in a table (the tests below use no AI credits).
-- NOTE: options must be a literal. OBJECT_CONSTRUCT('mode', <column>) with 'AGENTIC'
-- returns the error "Unsupported mode 'AGENTIC'. Supported modes: OCR, LAYOUT."
CREATE OR REPLACE TABLE AI_PARSE_TEST.PUBLIC.PARSE_RESULTS AS
SELECT 'OCR' AS mode, AI_PARSE_DOCUMENT(TO_FILE('@AI_PARSE_TEST.PUBLIC.DOCS','agentic_test.pdf'), {'mode':'OCR','page_split':true}, TRUE) AS res
UNION ALL
SELECT 'LAYOUT', AI_PARSE_DOCUMENT(TO_FILE('@AI_PARSE_TEST.PUBLIC.DOCS','agentic_test.pdf'), {'mode':'LAYOUT','page_split':true}, TRUE)
UNION ALL
SELECT 'AGENTIC', AI_PARSE_DOCUMENT(TO_FILE('@AI_PARSE_TEST.PUBLIC.DOCS','agentic_test.pdf'), {'mode':'AGENTIC','page_split':true}, TRUE);

-- Test 1: summary per mode
SELECT r.mode, ANY_VALUE(r.res:error::string) err, ANY_VALUE(r.res:metadata:pageCount::int) pages,
  SUM(LENGTH(p.value:content::string)) content_chars, SUM(ARRAY_SIZE(COALESCE(p.value:images, []))) images
FROM AI_PARSE_TEST.PUBLIC.PARSE_RESULTS r, LATERAL FLATTEN(r.res:value:pages) p
GROUP BY 1 ORDER BY 1;

-- Test 2: image classification in AGENTIC
SELECT p.value:index::int page, i.value:id::string img, i.value:results:image_type::string image_type,
  i.value:results:details:chart_type::string chart_type, i.value:results:details:diagram_type::string diagram_type,
  i.value:results:summary::string summary
FROM AI_PARSE_TEST.PUBLIC.PARSE_RESULTS r, LATERAL FLATTEN(r.res:value:pages) p, LATERAL FLATTEN(p.value:images) i
WHERE r.mode = 'AGENTIC' ORDER BY page, img;

-- Test 3: chart -> relational table (series / points)
SELECT i.value:id::string img, i.value:results:details:title::string title, s.value:name::string series,
  s.value:unit::string unit, pt.value:label::string label, pt.value:value::string value
FROM AI_PARSE_TEST.PUBLIC.PARSE_RESULTS r, LATERAL FLATTEN(r.res:value:pages) p, LATERAL FLATTEN(p.value:images) i,
  LATERAL FLATTEN(i.value:results:details:series) s, LATERAL FLATTEN(s.value:points) pt
WHERE r.mode = 'AGENTIC' AND i.value:results:image_type = 'chart'
ORDER BY img, series, pt.index;

-- Test 4: line chart reading accuracy (no value labels) vs source data
WITH truth AS (
  SELECT column1 series, column2 m, column3 v FROM VALUES
  ('Europe','Jan',12),('Europe','Feb',14),('Europe','Mar',15),('Europe','Apr',17),('Europe','May',21),('Europe','Jun',24),
  ('Europe','Jul',26),('Europe','Aug',25),('Europe','Sep',22),('Europe','Oct',19),('Europe','Nov',16),('Europe','Dec',13),
  ('North America','Jan',8),('North America','Feb',9),('North America','Mar',12),('North America','Apr',15),('North America','May',18),('North America','Jun',23),
  ('North America','Jul',28),('North America','Aug',30),('North America','Sep',26),('North America','Oct',20),('North America','Nov',14),('North America','Dec',10)),
ext AS (
  SELECT s.value:name::string series, pt.value:label::string m, pt.value:value::float v
  FROM AI_PARSE_TEST.PUBLIC.PARSE_RESULTS r, LATERAL FLATTEN(r.res:value:pages) p, LATERAL FLATTEN(p.value:images) i,
    LATERAL FLATTEN(i.value:results:details:series) s, LATERAL FLATTEN(s.value:points) pt
  WHERE r.mode = 'AGENTIC' AND i.value:results:details:chart_type = 'line'
    AND i.value:results:details:title ILIKE '%Active Users%')
SELECT t.series, COUNT(e.v) matched_points, SUM(IFF(e.v = t.v, 1, 0)) exact,
  ROUND(AVG(ABS(e.v - t.v)), 2) mae, MAX(ABS(e.v - t.v)) max_err
FROM truth t LEFT JOIN ext e ON e.series = t.series AND e.m = t.m GROUP BY 1;

-- Test 5: diagram as a graph + state signals from the screenshot
SELECT 'diagram edge' kind, c.value:from::string || ' -> ' || c.value:to::string item, c.value:label::string extra
FROM AI_PARSE_TEST.PUBLIC.PARSE_RESULTS r, LATERAL FLATTEN(r.res:value:pages) p, LATERAL FLATTEN(p.value:images) i,
  LATERAL FLATTEN(i.value:results:details:connections) c
WHERE r.mode = 'AGENTIC' AND i.value:results:image_type = 'diagram'
UNION ALL
SELECT 'screenshot', s.value::string, i.value:results:details:app_or_page::string
FROM AI_PARSE_TEST.PUBLIC.PARSE_RESULTS r, LATERAL FLATTEN(r.res:value:pages) p, LATERAL FLATTEN(p.value:images) i,
  LATERAL FLATTEN(i.value:results:details:state_signals) s
WHERE r.mode = 'AGENTIC' AND i.value:results:image_type = 'screenshot';

-- Test 6: is a given fact present in each mode's output
WITH txt AS (
  SELECT r.mode, LISTAGG(p.value:content::string, '\n') content,
         COALESCE(ARRAY_TO_STRING(ARRAY_AGG(p.value:images::string), ' '), '') images
  FROM AI_PARSE_TEST.PUBLIC.PARSE_RESULTS r, LATERAL FLATTEN(r.res:value:pages) p GROUP BY 1),
facts AS (SELECT column1 fact, column2 needle FROM VALUES
  ('Native table: 2,310 customers','2,310'), ('Bar label: $182M','182'),
  ('Line chart: Europe/Jul = 26 (no label)','"value":26'), ('Stacked: AMER Enterprise = 65 (no label)','"value":65'),
  ('Image table: $32,935.00','32,935'), ('Diagram: TARGET_LAG 5 min','TARGET_LAG 5 min'),
  ('Screenshot: error SALES.PUBLIC.ORDERS','SALES.PUBLIC.ORDERS'), ('Scanned memo: 500 credits limit','500 credits'),
  ('Photo: EXIT 412','EXIT 412'), ('Infographic: $1.2M','$1.2M'))
SELECT f.fact,
  MAX(IFF(t.mode = 'OCR', CONTAINS(t.content || t.images, f.needle), NULL)) ocr,
  MAX(IFF(t.mode = 'LAYOUT', CONTAINS(t.content || t.images, f.needle), NULL)) layout,
  MAX(IFF(t.mode = 'AGENTIC', CONTAINS(t.content || t.images, f.needle), NULL)) agentic
FROM facts f CROSS JOIN txt t GROUP BY f.fact ORDER BY f.fact;
