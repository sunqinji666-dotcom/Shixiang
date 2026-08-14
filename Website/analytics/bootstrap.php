<?php
declare(strict_types=1);

const SHIXIANG_ANALYTICS_RETENTION_DAYS = 180;

function analytics_db_path(): string
{
    $configured = getenv('SHIXIANG_ANALYTICS_DB');
    return $configured !== false && $configured !== ''
        ? $configured
        : '/www/wwwroot/shixiang.jack-sun.com-data/analytics.sqlite';
}

function analytics_db(): PDO
{
    static $db = null;
    if ($db instanceof PDO) {
        return $db;
    }

    $path = analytics_db_path();
    $directory = dirname($path);
    if (!is_dir($directory) && !mkdir($directory, 0750, true) && !is_dir($directory)) {
        throw new RuntimeException('Analytics data directory is unavailable.');
    }

    $db = new PDO('sqlite:' . $path, null, null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_TIMEOUT => 5,
    ]);
    $db->exec('PRAGMA journal_mode=WAL');
    $db->exec('PRAGMA synchronous=NORMAL');
    $db->exec('PRAGMA busy_timeout=5000');
    $db->exec('PRAGMA foreign_keys=ON');
    analytics_schema($db);
    return $db;
}

function analytics_schema(PDO $db): void
{
    $db->exec(<<<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    visitor_id TEXT NOT NULL,
    ip TEXT NOT NULL DEFAULT '',
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    active_seconds INTEGER NOT NULL DEFAULT 0,
    pageviews INTEGER NOT NULL DEFAULT 0,
    entry_path TEXT NOT NULL DEFAULT '/',
    current_path TEXT NOT NULL DEFAULT '/',
    referrer TEXT NOT NULL DEFAULT '',
    utm_source TEXT NOT NULL DEFAULT '',
    utm_medium TEXT NOT NULL DEFAULT '',
    utm_campaign TEXT NOT NULL DEFAULT '',
    user_agent TEXT NOT NULL DEFAULT '',
    device TEXT NOT NULL DEFAULT '未知设备',
    os TEXT NOT NULL DEFAULT '未知系统',
    browser TEXT NOT NULL DEFAULT '未知浏览器',
    language TEXT NOT NULL DEFAULT '',
    timezone TEXT NOT NULL DEFAULT '',
    screen TEXT NOT NULL DEFAULT '',
    viewport TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_sessions_first_seen ON sessions(first_seen);
CREATE INDEX IF NOT EXISTS idx_sessions_last_seen ON sessions(last_seen);
CREATE INDEX IF NOT EXISTS idx_sessions_visitor ON sessions(visitor_id);

CREATE TABLE IF NOT EXISTS pages (
    page_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    visitor_id TEXT NOT NULL,
    path TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    referrer TEXT NOT NULL DEFAULT '',
    started_at INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    active_seconds INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_pages_started ON pages(started_at);
CREATE INDEX IF NOT EXISTS idx_pages_session ON pages(session_id);
CREATE INDEX IF NOT EXISTS idx_pages_path ON pages(path);
SQL);
}

function analytics_json(array $payload, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, private, max-age=0');
    header('X-Content-Type-Options: nosniff');
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function analytics_text(mixed $value, int $maxLength = 500): string
{
    if (!is_string($value)) {
        return '';
    }
    $value = trim(str_replace(["\0", "\r", "\n"], '', $value));
    return mb_substr($value, 0, $maxLength, 'UTF-8');
}

function analytics_identifier(mixed $value): string
{
    $value = analytics_text($value, 80);
    return preg_match('/^[a-zA-Z0-9_-]{12,80}$/', $value) === 1 ? $value : '';
}

function analytics_client_ip(): string
{
    return analytics_text($_SERVER['REMOTE_ADDR'] ?? '', 64);
}

function analytics_same_origin(): bool
{
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    if ($origin === '') {
        return true;
    }
    $originHost = parse_url($origin, PHP_URL_HOST);
    $requestHost = explode(':', $_SERVER['HTTP_HOST'] ?? '')[0];
    return is_string($originHost) && hash_equals(strtolower($requestHost), strtolower($originHost));
}

function analytics_user_agent(string $ua, bool $mobileHint): array
{
    $browser = '其他浏览器';
    if (preg_match('/Edg\//i', $ua)) {
        $browser = 'Edge';
    } elseif (preg_match('/OPR\//i', $ua)) {
        $browser = 'Opera';
    } elseif (preg_match('/Chrome\//i', $ua)) {
        $browser = 'Chrome';
    } elseif (preg_match('/Firefox\//i', $ua)) {
        $browser = 'Firefox';
    } elseif (preg_match('/Safari\//i', $ua)) {
        $browser = 'Safari';
    }

    $os = '其他系统';
    if (preg_match('/iPhone|iPad|iPod/i', $ua)) {
        $os = 'iOS / iPadOS';
    } elseif (preg_match('/Macintosh|Mac OS X/i', $ua)) {
        $os = 'macOS';
    } elseif (preg_match('/Android/i', $ua)) {
        $os = 'Android';
    } elseif (preg_match('/Windows/i', $ua)) {
        $os = 'Windows';
    } elseif (preg_match('/Linux/i', $ua)) {
        $os = 'Linux';
    }

    $device = $mobileHint || preg_match('/Mobile|Android|iPhone|iPod/i', $ua)
        ? '手机'
        : (preg_match('/iPad|Tablet/i', $ua) ? '平板' : '电脑');

    return [$device, $os, $browser];
}

function analytics_prune(PDO $db): void
{
    if (random_int(1, 100) !== 1) {
        return;
    }
    $cutoff = time() - SHIXIANG_ANALYTICS_RETENTION_DAYS * 86400;
    $statement = $db->prepare('DELETE FROM sessions WHERE last_seen < :cutoff');
    $statement->execute([':cutoff' => $cutoff]);
}
