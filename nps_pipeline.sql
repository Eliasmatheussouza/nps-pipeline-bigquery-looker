########################## NPS Physical Stores — CONSOLIDATED ##################################
-- Main table with all metrics at row level
-- Consolidates: NPS + reason mapping (DE-PARA) + store dimension + customer profile + transactions + avg ticket/spending
-- Full rebuild each run (no incremental load)
--
-- DATE CRITERIA:
--   Before the taxonomy cutover date: "month"/"date" based on survey_answered_at (response date)
--   From the cutover date onward: "month"/"date" based on order_created_at (order date)
--   Cutoff: responses accepted up to day 7 of the month following the order
--
-- NOTE: this script has been anonymized for portfolio purposes.
-- All project/dataset/table identifiers were replaced with generic placeholders,
-- and any company-specific naming was removed. Logic, joins and business rules
-- are unchanged from the production version.

-- ────────────────────────────────────────────────
-- Normalization functions used in the reason-mapping correction (DE-PARA)
-- ────────────────────────────────────────────────
CREATE TEMP FUNCTION normalize_reason(txt STRING) AS (
  UPPER(TRIM(
    REGEXP_REPLACE(
      REGEXP_REPLACE(txt, r'[\x{FE0F}\x{200B}\x{200D}\x{2060}]', ''),
      r'\s+', ' '
    )
  ))
);

CREATE TEMP FUNCTION normalize_reason_no_punct(txt STRING) AS (
  REGEXP_REPLACE(normalize_reason(txt), r'[\/,\(\)]', '')
);

CREATE TEMP FUNCTION sentence_case(txt STRING) AS (
  CONCAT(UPPER(SUBSTR(txt, 1, 1)), LOWER(SUBSTR(txt, 2)))
);

CREATE OR REPLACE TABLE `analytics-portfolio.nps_panel.nps_physical_consolidated_temp` AS (

WITH

-- ────────────────────────────────────────────────
-- 1. NPS base (raw survey responses)
--    Primary source of physical-store NPS responses
--    Deduplicated by external_id + reason
--    Date criteria applied per the cutover rule above
-- ────────────────────────────────────────────────
nps_base AS (
  SELECT
    id                                              AS response_id,
    -- date criteria: history uses survey_answered_at, recent data uses order_created_at
    CASE
      WHEN DATE(survey_answered_at) < '2026-06-19'
        THEN EXTRACT(YEAR  FROM DATE(survey_answered_at))
      ELSE EXTRACT(YEAR  FROM DATE(order_created_at))
    END                                             AS year,

    CASE
      WHEN DATE(survey_answered_at) < '2026-06-19'
        THEN EXTRACT(MONTH FROM DATE(survey_answered_at))
      ELSE EXTRACT(MONTH FROM DATE(order_created_at))
    END                                             AS month,

    CASE
      WHEN DATE(survey_answered_at) < '2026-06-19'
        THEN DATE(survey_answered_at)
      ELSE DATE(order_created_at)
    END                                             AS ref_date,

    DATE(order_created_at)                          AS order_date_raw,
    SAFE_CAST(external_id AS STRING)                AS order_code,
    reason                                          AS reasons,
    classification,
    comment,
    score,

    -- FIX: decode "+" back to space and extract only the numeric store code
    -- (accepts formats like "101", "5116", "L527 - DOWNTOWN", "L135+-+MALL+NORTH")
    SAFE_CAST(
      REGEXP_EXTRACT(REPLACE(store_ref, '+', ' '), r'^\s*L?(\d+)')
      AS INT64
    )                                               AS store_id,

    LPAD(SAFE_CAST(customer_ref AS STRING), 11, "0") AS customer_tax_id,
    COUNT(CASE WHEN classification = 'detractor' THEN classification END) AS detractors,
    COUNT(CASE WHEN classification = 'neutral'   THEN classification END) AS neutrals,
    COUNT(CASE WHEN classification = 'promoter'  THEN classification END) AS promoters,
    COUNT(*) AS respondents
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (
        PARTITION BY external_id, COALESCE(reason, 'no_reason')
        ORDER BY survey_answered_at DESC
      ) AS rn
    FROM `analytics-portfolio.customer_behavior.nps_responses`
    WHERE (journey LIKE '%physical%' OR journey LIKE '%transactional%')
      AND store_ref IS NOT NULL
      AND classification IS NOT NULL
      -- FIX: remove values that aren't real physical stores
      AND LOWER(TRIM(store_ref)) NOT IN (
        'delivery', 'market_research', 'last_purchase_store', 'physical'
      )
  )
  WHERE rn = 1
  -- cutoff for the new criteria: only accept responses up to day 7 of the month following the order
    AND (
      DATE(survey_answered_at) < '2026-06-19' -- history: no cutoff restriction
      OR DATE(survey_answered_at) <= DATE_ADD(
           DATE_TRUNC(DATE(order_created_at), MONTH),
           INTERVAL 37 DAY             -- day 7 of the following month
         )
    )
  GROUP BY ALL
),

-- ────────────────────────────────────────────────
-- 1.5. Reason mapping (DE-PARA) — Physical Store channel
--      old_reason -> new_reason, by classification
--      Match order: exact -> punctuation-stripped -> already a new_reason -> keep original
--      score_band always resolved (via mapping table or direct fallback from classification)
-- ────────────────────────────────────────────────
reason_mapping_norm AS (
  SELECT
    *,
    normalize_reason(old_reason)          AS old_reason_norm,
    normalize_reason_no_punct(old_reason) AS old_reason_norm_np,
    normalize_reason(new_reason)          AS new_reason_norm
  FROM `analytics-portfolio.nps_panel.reason_mapping`
  WHERE channel = 'Physical Store'
),

nps_reason_corrected AS (
  SELECT
    n.* EXCEPT (reasons),

    sentence_case(
      COALESCE(d1.new_reason, d2.new_reason, d3.new_reason, n.reasons, 'No response')
    )                                                                     AS reasons,

    COALESCE(
      d1.score_band, d2.score_band, d3.score_band,
      CASE n.classification
        WHEN 'detractor' THEN '0-6'
        WHEN 'neutral'   THEN '7-8'
        WHEN 'promoter'  THEN '9-10'
      END
    )                                                                     AS reason_score_band,

    COALESCE(d1.reason_group, d2.reason_group, d3.reason_group)           AS reason_group

  FROM nps_base n
  LEFT JOIN reason_mapping_norm d1
    ON  d1.old_reason_norm = normalize_reason(n.reasons)
    AND LOWER(d1.base_classification) = n.classification
  LEFT JOIN reason_mapping_norm d2
    ON  d1.old_reason IS NULL
    AND d2.old_reason_norm_np = normalize_reason_no_punct(n.reasons)
    AND LOWER(d2.base_classification) = n.classification
  LEFT JOIN reason_mapping_norm d3
    ON  d1.old_reason IS NULL AND d2.old_reason IS NULL
    AND d3.new_reason_norm = normalize_reason(n.reasons)
    AND LOWER(d3.base_classification) = n.classification
),

-- ────────────────────────────────────────────────
-- 2. Store dimension
--    Provides: store_name, region_id, district_name, state, store_type
-- ────────────────────────────────────────────────
dim_store AS (
  SELECT
    store_id       AS store_id_formatted,
    store_name,
    store_type,
    region_id,
    district_name,
    state
  FROM `analytics-portfolio.retail_dims.dim_store`
),

-- ────────────────────────────────────────────────
-- 3. Core transactions
--    Excludes department and payment_type
--    Only used to get: order_date, order_id, customer_tax_id
-- ────────────────────────────────────────────────
customer_ids AS (
  SELECT DISTINCT
    COALESCE(
      customer_cpf,
      customer_cnpj,
      exclusive_physical.customer_cpf_ame,
      exclusive_physical.employee_cpf
    ) AS tax_id,
    customer_id
  FROM `analytics-portfolio.sales.transactions`
),

customer_order AS (
  SELECT DISTINCT
    DATETIME(order_date)                            AS order_datetime,
    order_id,
    order_date                                      AS order_date_raw,
    SAFE_CAST(c.customer_id AS STRING)              AS customer_id,
    COALESCE(
      customer_cpf,
      customer_cnpj,
      exclusive_physical.customer_cpf_ame,
      exclusive_physical.employee_cpf
    )                                               AS tax_id
  FROM `analytics-portfolio.sales.transactions` t
  LEFT JOIN customer_ids c
    ON COALESCE(
      customer_cpf,
      customer_cnpj,
      exclusive_physical.customer_cpf_ame,
      exclusive_physical.employee_cpf
    ) = c.tax_id
),

-- ────────────────────────────────────────────────
-- 4. Customer profile
--    Provides: customer_gender, customer_birth_date
--    Deduplicated by most recent record per tax id
-- ────────────────────────────────────────────────
profile_raw AS (
  SELECT DISTINCT
    brand,
    COALESCE(customer_cnpj, customer_cpf)           AS tax_id,
    customer_gender,
    customer_birth_date,
    customer_id,
    customer_last_modification                      AS last_modified,
    ROW_NUMBER() OVER (
      PARTITION BY customer_cpf
      ORDER BY COALESCE(
        customer_last_modification,
        customer_registration_date
      ) DESC
    ) AS record_order
  FROM `analytics-portfolio.customers.profile`
  QUALIFY record_order = 1
),

profile_last AS (
  SELECT brand, tax_id, MAX(last_modified) AS last_modified
  FROM profile_raw
  GROUP BY brand, tax_id
),

profile AS (
  SELECT
    p.tax_id,
    p.customer_gender,
    p.customer_birth_date,
    p.customer_id
  FROM profile_raw p
  INNER JOIN profile_last l
    ON  p.tax_id        = l.tax_id
    AND p.brand          = l.brand
    AND p.last_modified   = l.last_modified
),

-- ────────────────────────────────────────────────
-- 5. Average ticket and spending per customer — trailing 12 months
-- ────────────────────────────────────────────────
transactions_by_customer AS (
  SELECT
    COALESCE(
      customer_cpf,
      customer_cnpj,
      exclusive_physical.customer_cpf_ame,
      exclusive_physical.employee_cpf
    )                                               AS tax_id,
    SAFE_DIVIDE(
      SUM(order_line_total_value),
      COUNT(DISTINCT order_id)
    )                                               AS avg_ticket,
    SUM(order_line_total_value)                     AS spending
  FROM `analytics-portfolio.sales.transactions`
  WHERE order_line_total_value IS NOT NULL
    AND DATE(order_date) >= DATE_SUB(
      CURRENT_DATE('America/Sao_Paulo'), INTERVAL 12 MONTH
    )
  GROUP BY
    COALESCE(
      customer_cpf,
      customer_cnpj,
      exclusive_physical.customer_cpf_ame,
      exclusive_physical.employee_cpf
    )
),

-- ────────────────────────────────────────────────
-- 6. NPS + profile join
--    Enriches NPS responses with customer data
--    Uses nps_reason_corrected (reason already fixed by the mapping table)
-- ────────────────────────────────────────────────
nps_enriched AS (
  SELECT DISTINCT
    n.*,
    DATE_DIFF(
      CURRENT_DATE('America/Sao_Paulo'),
      DATE(p.customer_birth_date),
      YEAR
    )                                               AS age,
    p.customer_gender,
    p.tax_id
  FROM nps_reason_corrected n
  LEFT JOIN profile p ON n.customer_tax_id = p.tax_id
),

-- ────────────────────────────────────────────────
-- 7. Final base — NPS + transactions + store dimension
-- ────────────────────────────────────────────────
base AS (
  SELECT DISTINCT
    n.response_id,
    n.ref_date                                      AS date_modified,
    DATE_TRUNC(n.ref_date, MONTH)                   AS month,
    SAFE_CAST(n.store_id AS INT64)                  AS store_id,
    ds.store_name,
    ds.region_id,
    ds.district_name,
    ds.state,
    ds.store_type,
    n.reasons                                       AS reason,
    n.reason_score_band,
    n.reason_group,
    n.classification,
    n.comment,
    n.score,
    n.tax_id,
    n.customer_gender,
    CASE
      WHEN n.age BETWEEN 0  AND 24 THEN "18-24"
      WHEN n.age BETWEEN 25 AND 34 THEN "25-34"
      WHEN n.age BETWEEN 35 AND 44 THEN "35-44"
      WHEN n.age BETWEEN 45 AND 54 THEN "45-54"
      WHEN n.age BETWEEN 55 AND 64 THEN "55-64"
      WHEN n.age > 64              THEN "65+"
      ELSE "N/A"
    END                                             AS age_band,
    SAFE_CAST(n.age AS STRING)                      AS age,
    DATE(c.order_datetime)                          AS order_date,
    c.order_datetime                                AS order_datetime_raw,
    DATE(c.order_datetime)                          AS order_date_converted,
    c.order_id,
    COUNT(DISTINCT CASE WHEN n.classification = "detractor"
      THEN n.response_id END)                       AS detractors,
    COUNT(DISTINCT CASE WHEN n.classification = "neutral"
      THEN n.response_id END)                       AS neutrals,
    COUNT(DISTINCT CASE WHEN n.classification = "promoter"
      THEN n.response_id END)                       AS promoters
  FROM nps_enriched n
  LEFT JOIN customer_order c
    ON  n.order_code = c.order_id
  LEFT JOIN dim_store ds
    ON  SAFE_CAST(n.store_id AS INT64) = ds.store_id_formatted
  GROUP BY ALL
),

-- ────────────────────────────────────────────────
-- 8. Cross join of age bands x dates
--    (guarantees a full spine so every band/day combination exists)
-- ────────────────────────────────────────────────
parameters AS (
  SELECT
    DATE '2025-01-01' AS start_date,
    DATE '2026-12-31' AS end_date
),

dates AS (
  SELECT date_col AS ref_date
  FROM UNNEST(GENERATE_DATE_ARRAY(
    (SELECT start_date FROM parameters),
    (SELECT end_date    FROM parameters),
    INTERVAL 1 DAY
  )) AS date_col
),

age_bands AS (
  SELECT '18-24' AS age_band UNION ALL
  SELECT '25-34'              UNION ALL
  SELECT '35-44'              UNION ALL
  SELECT '45-54'              UNION ALL
  SELECT '55-64'              UNION ALL
  SELECT '65+'                UNION ALL
  SELECT 'ALL'                UNION ALL
  SELECT 'N/A'
),

spine AS (
  SELECT d.ref_date, a.age_band
  FROM dates d
  CROSS JOIN age_bands a
)

-- ────────────────────────────────────────────────
-- 9. FINAL SELECT — 32 columns (30 original + reason_score_band + reason_group)
-- ────────────────────────────────────────────────
SELECT DISTINCT

  b.response_id,                                          -- 1
  f.ref_date                    AS date_modified,          -- 2
  DATE_TRUNC(f.ref_date, MONTH) AS month,                  -- 3
  b.store_id,                                              -- 4
  b.store_name,                                            -- 5
  b.region_id,                                             -- 6
  b.district_name,                                         -- 7
  b.state,                                                 -- 8
  b.store_type,                                            -- 9
  b.reason,                                                -- 10
  b.reason_score_band,                                     -- 11 (new)
  b.reason_group,                                          -- 12 (new)
  b.classification,                                        -- 13
  b.comment,                                               -- 14
  b.score,                                                 -- 15
  b.tax_id,                                                -- 16
  b.customer_gender,                                       -- 17
  f.age_band,                                              -- 18
  b.age,                                                   -- 19
  b.order_date,                                            -- 20
  b.order_datetime_raw,                                    -- 21
  b.order_date_converted,                                  -- 22
  b.order_id,                                              -- 23
  b.detractors,                                            -- 24
  b.neutrals,                                              -- 25
  b.promoters,                                             -- 26

  ROUND(SAFE_DIVIDE(
    SUM(b.promoters) - SUM(b.detractors),
    NULLIF(SUM(b.promoters) + SUM(b.neutrals) + SUM(b.detractors), 0)
  ) * 100, 0)                   AS store_nps,              -- 27

  CASE
    WHEN SAFE_DIVIDE(
      SUM(b.promoters) - SUM(b.detractors),
      NULLIF(SUM(b.promoters) + SUM(b.neutrals) + SUM(b.detractors), 0)
    ) * 100 <  0  THEN 'Critical'
    WHEN SAFE_DIVIDE(
      SUM(b.promoters) - SUM(b.detractors),
      NULLIF(SUM(b.promoters) + SUM(b.neutrals) + SUM(b.detractors), 0)
    ) * 100 <= 50 THEN 'Quality'
    ELSE 'Excellence'
  END                           AS nps_band,               -- 28

  CASE
    WHEN SAFE_DIVIDE(
      SUM(b.promoters) - SUM(b.detractors),
      NULLIF(SUM(b.promoters) + SUM(b.neutrals) + SUM(b.detractors), 0)
    ) * 100 <  0  THEN 1
    WHEN SAFE_DIVIDE(
      SUM(b.promoters) - SUM(b.detractors),
      NULLIF(SUM(b.promoters) + SUM(b.neutrals) + SUM(b.detractors), 0)
    ) * 100 <= 50 THEN 2
    ELSE 3
  END                           AS nps_band_order,          -- 29

  t.avg_ticket,                                             -- 30
  t.spending,                                               -- 31

  TIMESTAMP(FORMAT_TIMESTAMP(
    '%F %X', CURRENT_TIMESTAMP(), 'America/Sao_Paulo'
  ))                            AS refreshed_at             -- 32

FROM spine f
LEFT JOIN base b
  ON  f.age_band     = b.age_band
  AND DATE(f.ref_date) = DATE(b.date_modified)
LEFT JOIN transactions_by_customer t
  ON  b.tax_id         = t.tax_id

WHERE b.response_id IS NOT NULL   -- FIX: drop spine rows without a real response

GROUP BY ALL

);


########################## NPS Physical Stores — PURCHASE FREQUENCY BY CLASSIFICATION ##################################
-- Auxiliary table with purchase-frequency distribution
-- by NPS classification (promoter / neutral / detractor)
-- Frequency = number of orders per customer over the trailing 12 months
-- Grouped by classification + frequency band

CREATE OR REPLACE TABLE `analytics-portfolio.nps_panel.purchase_frequency_by_classification_temp` AS (

WITH

customer_classification AS (
  SELECT DISTINCT
    tax_id,
    classification
  FROM `analytics-portfolio.nps_panel.nps_physical_consolidated_temp`
  WHERE tax_id IS NOT NULL
    AND classification IN ('promoter', 'neutral', 'detractor')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY tax_id
    ORDER BY date_modified DESC
  ) = 1
),

orders_by_customer AS (
  SELECT
    n.tax_id,
    n.classification,
    COUNT(DISTINCT t.order_id) AS order_count
  FROM customer_classification n
  LEFT JOIN `analytics-portfolio.sales.transactions` t
    ON n.tax_id = COALESCE(
      t.customer_cpf,
      t.customer_cnpj,
      t.exclusive_physical.customer_cpf_ame,
      t.exclusive_physical.employee_cpf
    )
    AND DATE(t.order_date) >= DATE_SUB(
      CURRENT_DATE('America/Sao_Paulo'), INTERVAL 12 MONTH
    )
    AND t.order_line_total_value IS NOT NULL
  GROUP BY n.tax_id, n.classification
),

bands AS (
  SELECT
    classification,
    CASE
      WHEN order_count = 1             THEN '1x'
      WHEN order_count BETWEEN 2 AND 3 THEN '2-3x'
      WHEN order_count BETWEEN 4 AND 6 THEN '4-6x'
      ELSE '7x or more'
    END                                AS frequency_band,
    COUNT(DISTINCT tax_id)             AS customer_count
  FROM orders_by_customer
  GROUP BY classification, frequency_band
),

totals AS (
  SELECT
    classification,
    SUM(customer_count) AS total_customers_by_classification
  FROM bands
  GROUP BY classification
)

SELECT
  b.classification,                                       -- 1
  b.frequency_band,                                        -- 2
  b.customer_count,                                        -- 3
  t.total_customers_by_classification,                     -- 4
  ROUND(SAFE_DIVIDE(
    b.customer_count,
    t.total_customers_by_classification
  ) * 100, 1)                   AS customer_pct            -- 5
FROM bands b
LEFT JOIN totals t
  ON b.classification = t.classification
ORDER BY
  b.classification,
  b.frequency_band

);
