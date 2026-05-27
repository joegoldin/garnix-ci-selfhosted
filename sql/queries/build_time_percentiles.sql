WITH MonthlyBuildTimes AS (
  SELECT
    repo_user,
    date_trunc('month', start_time) AS month,
    SUM(LEAST(120, EXTRACT(EPOCH FROM (end_time - start_time)) / 60)) AS build_time_minutes
  FROM
    public.builds
  WHERE
    end_time IS NOT NULL
    AND start_time >= NOW() - INTERVAL '12 months'
  GROUP BY
    repo_user,
    date_trunc('month', start_time)
  ORDER BY
    repo_user,
    month
)
, Percentiles AS (
    SELECT
        percentile_cont(0.01) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_1,
        percentile_cont(0.05) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_5,
        percentile_cont(0.10) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_10,
        percentile_cont(0.20) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_20,
        percentile_cont(0.30) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_30,
        percentile_cont(0.40) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_40,
        percentile_cont(0.50) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_50,
        percentile_cont(0.75) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_75,
        percentile_cont(0.90) WITHIN GROUP (ORDER BY build_time_minutes DESC) AS percentile_90
    FROM
        MonthlyBuildTimes
)
SELECT * FROM Percentiles;
