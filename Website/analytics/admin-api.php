<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    header('Allow: GET');
    analytics_json(['ok' => false, 'error' => 'method_not_allowed'], 405);
}

$range = analytics_text($_GET['range'] ?? '7d', 10);
$rangeDays = ['1d' => 1, '7d' => 7, '30d' => 30, '90d' => 90, 'all' => 3650][$range] ?? 7;
$cutoff = $range === 'all' ? 0 : time() - $rangeDays * 86400;

try {
    $db = analytics_db();

    $overviewStatement = $db->prepare(<<<'SQL'
SELECT
    COUNT(*) AS sessions,
    COUNT(DISTINCT visitor_id) AS visitors,
    COALESCE(SUM(pageviews), 0) AS pageviews,
    COALESCE(ROUND(AVG(active_seconds)), 0) AS avg_active_seconds,
    COALESCE(ROUND(100.0 * AVG(CASE WHEN pageviews <= 1 AND active_seconds < 10 THEN 1.0 ELSE 0.0 END), 1), 0) AS bounce_rate,
    COALESCE(SUM(CASE WHEN last_seen >= :live_cutoff THEN 1 ELSE 0 END), 0) AS live_sessions
FROM sessions
WHERE first_seen >= :cutoff
SQL);
    $overviewStatement->execute([':cutoff' => $cutoff, ':live_cutoff' => time() - 300]);
    $overview = $overviewStatement->fetch() ?: [];

    $timelineStatement = $db->prepare(<<<'SQL'
SELECT
    date(first_seen, 'unixepoch', '+8 hours') AS bucket,
    COUNT(*) AS sessions,
    COUNT(DISTINCT visitor_id) AS visitors,
    COALESCE(SUM(pageviews), 0) AS pageviews
FROM sessions
WHERE first_seen >= :cutoff
GROUP BY bucket
ORDER BY bucket ASC
SQL);
    $timelineStatement->execute([':cutoff' => $cutoff]);

    $topPagesStatement = $db->prepare(<<<'SQL'
SELECT path, MAX(title) AS title, COUNT(*) AS views, COUNT(DISTINCT visitor_id) AS visitors,
       COALESCE(ROUND(AVG(active_seconds)), 0) AS avg_seconds
FROM pages
WHERE started_at >= :cutoff
GROUP BY path
ORDER BY views DESC, avg_seconds DESC
LIMIT 12
SQL);
    $topPagesStatement->execute([':cutoff' => $cutoff]);

    $dimension = static function (PDO $db, string $column, int $cutoff): array {
        $allowed = ['device', 'os', 'browser', 'language', 'timezone'];
        if (!in_array($column, $allowed, true)) {
            return [];
        }
        $statement = $db->prepare("SELECT {$column} AS label, COUNT(*) AS value FROM sessions WHERE first_seen >= :cutoff GROUP BY {$column} ORDER BY value DESC LIMIT 10");
        $statement->execute([':cutoff' => $cutoff]);
        return $statement->fetchAll();
    };

    $recentStatement = $db->prepare(<<<'SQL'
SELECT session_id, visitor_id, ip, first_seen, last_seen, active_seconds, pageviews,
       entry_path, current_path, referrer, utm_source, utm_medium, utm_campaign,
       device, os, browser, language, timezone, screen, viewport
FROM sessions
WHERE first_seen >= :cutoff
ORDER BY last_seen DESC
LIMIT 120
SQL);
    $recentStatement->execute([':cutoff' => $cutoff]);

    $visitorsStatement = $db->prepare(<<<'SQL'
SELECT visitor_id, MAX(ip) AS ip, MIN(first_seen) AS first_seen, MAX(last_seen) AS last_seen,
       COUNT(*) AS sessions, COALESCE(SUM(pageviews), 0) AS pageviews,
       COALESCE(SUM(active_seconds), 0) AS active_seconds,
       MAX(device) AS device, MAX(os) AS os, MAX(browser) AS browser,
       MAX(current_path) AS current_path
FROM sessions
WHERE first_seen >= :cutoff
GROUP BY visitor_id
ORDER BY last_seen DESC
LIMIT 120
SQL);
    $visitorsStatement->execute([':cutoff' => $cutoff]);

    $referrerStatement = $db->prepare("SELECT referrer, utm_source, COUNT(*) AS value FROM sessions WHERE first_seen >= :cutoff GROUP BY referrer, utm_source ORDER BY value DESC LIMIT 30");
    $referrerStatement->execute([':cutoff' => $cutoff]);
    $sources = [];
    foreach ($referrerStatement->fetchAll() as $row) {
        $label = analytics_text($row['utm_source'] ?? '', 120);
        if ($label === '') {
            $referrer = analytics_text($row['referrer'] ?? '', 800);
            $host = $referrer !== '' ? parse_url($referrer, PHP_URL_HOST) : null;
            $label = is_string($host) && $host !== '' ? $host : '直接访问';
        }
        $sources[$label] = ($sources[$label] ?? 0) + (int) $row['value'];
    }
    arsort($sources);
    $sourceRows = [];
    foreach (array_slice($sources, 0, 10, true) as $label => $value) {
        $sourceRows[] = ['label' => $label, 'value' => $value];
    }

    analytics_json([
        'ok' => true,
        'range' => $range,
        'generatedAt' => time(),
        'retentionDays' => SHIXIANG_ANALYTICS_RETENTION_DAYS,
        'overview' => array_map('intval', $overview),
        'timeline' => $timelineStatement->fetchAll(),
        'topPages' => $topPagesStatement->fetchAll(),
        'devices' => $dimension($db, 'device', $cutoff),
        'systems' => $dimension($db, 'os', $cutoff),
        'browsers' => $dimension($db, 'browser', $cutoff),
        'languages' => $dimension($db, 'language', $cutoff),
        'sources' => $sourceRows,
        'recent' => $recentStatement->fetchAll(),
        'visitors' => $visitorsStatement->fetchAll(),
    ]);
} catch (Throwable $error) {
    error_log('Shixiang analytics admin: ' . $error->getMessage());
    analytics_json(['ok' => false, 'error' => 'analytics_unavailable'], 503);
}
