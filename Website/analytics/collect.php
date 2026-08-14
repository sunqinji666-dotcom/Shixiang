<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Allow: POST');
    analytics_json(['ok' => false, 'error' => 'method_not_allowed'], 405);
}
if (!analytics_same_origin()) {
    analytics_json(['ok' => false, 'error' => 'origin_rejected'], 403);
}

$length = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
if ($length > 12288) {
    analytics_json(['ok' => false, 'error' => 'payload_too_large'], 413);
}

$raw = file_get_contents('php://input');
$payload = json_decode($raw !== false ? $raw : '', true);
if (!is_array($payload)) {
    analytics_json(['ok' => false, 'error' => 'invalid_json'], 400);
}

$event = analytics_text($payload['event'] ?? '', 20);
$visitorId = analytics_identifier($payload['visitorId'] ?? '');
$sessionId = analytics_identifier($payload['sessionId'] ?? '');
$pageId = analytics_identifier($payload['pageId'] ?? '');
if (!in_array($event, ['pageview', 'heartbeat', 'exit'], true) || $visitorId === '' || $sessionId === '' || $pageId === '') {
    analytics_json(['ok' => false, 'error' => 'invalid_event'], 422);
}

$now = time();
$path = analytics_text($payload['path'] ?? '/', 500);
if ($path === '' || !str_starts_with($path, '/')) {
    $path = '/';
}
$title = analytics_text($payload['title'] ?? '', 200);
$referrer = analytics_text($payload['referrer'] ?? '', 800);
$language = analytics_text($payload['language'] ?? '', 40);
$timezone = analytics_text($payload['timezone'] ?? '', 80);
$screen = analytics_text($payload['screen'] ?? '', 30);
$viewport = analytics_text($payload['viewport'] ?? '', 30);
$activeSeconds = max(0, min(86400, (int) ($payload['activeSeconds'] ?? 0)));
$mobileHint = (bool) ($payload['mobile'] ?? false);
$ua = analytics_text($_SERVER['HTTP_USER_AGENT'] ?? '', 800);
if (preg_match('/bot|crawler|spider|slurp|lighthouse|pagespeed|headless/i', $ua)) {
    analytics_json(['ok' => true, 'ignored' => 'automated_client']);
}
[$device, $os, $browser] = analytics_user_agent($ua, $mobileHint);
$ip = analytics_client_ip();
$utmSource = analytics_text($payload['utmSource'] ?? '', 120);
$utmMedium = analytics_text($payload['utmMedium'] ?? '', 120);
$utmCampaign = analytics_text($payload['utmCampaign'] ?? '', 160);

try {
    $db = analytics_db();
    $db->beginTransaction();

    $insertSession = $db->prepare(<<<'SQL'
INSERT OR IGNORE INTO sessions (
    session_id, visitor_id, ip, first_seen, last_seen, active_seconds, pageviews,
    entry_path, current_path, referrer, utm_source, utm_medium, utm_campaign,
    user_agent, device, os, browser, language, timezone, screen, viewport
) VALUES (
    :session_id, :visitor_id, :ip, :now, :now, 0, 0,
    :path, :path, :referrer, :utm_source, :utm_medium, :utm_campaign,
    :user_agent, :device, :os, :browser, :language, :timezone, :screen, :viewport
)
SQL);
    $insertSession->execute([
        ':session_id' => $sessionId,
        ':visitor_id' => $visitorId,
        ':ip' => $ip,
        ':now' => $now,
        ':path' => $path,
        ':referrer' => $referrer,
        ':utm_source' => $utmSource,
        ':utm_medium' => $utmMedium,
        ':utm_campaign' => $utmCampaign,
        ':user_agent' => $ua,
        ':device' => $device,
        ':os' => $os,
        ':browser' => $browser,
        ':language' => $language,
        ':timezone' => $timezone,
        ':screen' => $screen,
        ':viewport' => $viewport,
    ]);

    if ($event === 'pageview') {
        $insertPage = $db->prepare(<<<'SQL'
INSERT OR IGNORE INTO pages (
    page_id, session_id, visitor_id, path, title, referrer, started_at, last_seen, active_seconds
) VALUES (:page_id, :session_id, :visitor_id, :path, :title, :referrer, :now, :now, 0)
SQL);
        $insertPage->execute([
            ':page_id' => $pageId,
            ':session_id' => $sessionId,
            ':visitor_id' => $visitorId,
            ':path' => $path,
            ':title' => $title,
            ':referrer' => $referrer,
            ':now' => $now,
        ]);
        if ($insertPage->rowCount() > 0) {
            $db->prepare('UPDATE sessions SET pageviews = pageviews + 1 WHERE session_id = :session_id')
                ->execute([':session_id' => $sessionId]);
        }
    }

    $updatePage = $db->prepare(<<<'SQL'
UPDATE pages
SET last_seen = :now,
    active_seconds = MAX(active_seconds, :active_seconds),
    title = CASE WHEN :title = '' THEN title ELSE :title END
WHERE page_id = :page_id AND session_id = :session_id
SQL);
    $updatePage->execute([
        ':now' => $now,
        ':active_seconds' => $activeSeconds,
        ':title' => $title,
        ':page_id' => $pageId,
        ':session_id' => $sessionId,
    ]);

    $activeTotal = (int) $db->query("SELECT COALESCE(SUM(active_seconds), 0) FROM pages WHERE session_id = " . $db->quote($sessionId))->fetchColumn();
    $updateSession = $db->prepare(<<<'SQL'
UPDATE sessions
SET last_seen = :now,
    active_seconds = :active_seconds,
    current_path = :path,
    ip = :ip,
    viewport = :viewport
WHERE session_id = :session_id
SQL);
    $updateSession->execute([
        ':now' => $now,
        ':active_seconds' => $activeTotal,
        ':path' => $path,
        ':ip' => $ip,
        ':viewport' => $viewport,
        ':session_id' => $sessionId,
    ]);

    $db->commit();
    analytics_prune($db);
    analytics_json(['ok' => true]);
} catch (Throwable $error) {
    if (isset($db) && $db instanceof PDO && $db->inTransaction()) {
        $db->rollBack();
    }
    error_log('Shixiang analytics collect: ' . $error->getMessage());
    analytics_json(['ok' => false, 'error' => 'storage_unavailable'], 503);
}
