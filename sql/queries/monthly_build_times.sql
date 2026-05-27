SELECT
  repo_user,
  date_trunc('month', start_time) AS month,
  SUM(LEAST(120, EXTRACT(EPOCH FROM (end_time - start_time)) / 60)) AS total_build_time
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
  month;
