import socketio
import redis
from redis import asyncio as aioredis
from urllib.parse import urlparse
import logging

log = logging.getLogger(__name__)


def parse_redis_service_url(redis_url):
    parsed_url = urlparse(redis_url)
    if parsed_url.scheme != "redis":
        raise ValueError("Invalid Redis URL scheme. Must be 'redis'.")

    return {
        "username": parsed_url.username or None,
        "password": parsed_url.password or None,
        "service": parsed_url.hostname or "mymaster",
        "port": parsed_url.port or 6379,
        "db": int(parsed_url.path.lstrip("/") or 0),
    }


def get_redis_connection(redis_url, redis_sentinels, decode_responses=True):
    log.info(f"Attempting to connect to Redis. URL: '{redis_url}', Sentinels: {redis_sentinels}")
    try:
        if redis_sentinels:
            redis_config = parse_redis_service_url(redis_url)
            log.info(f"Connecting via Sentinel. Config: {redis_config}, Sentinel List: {redis_sentinels}")
            sentinel = redis.sentinel.Sentinel(
                redis_sentinels,
                # socket_timeout=0.1, # Optional: for quicker connection timeout testing
                db=redis_config["db"],
                username=redis_config["username"],
                password=redis_config["password"],
                decode_responses=decode_responses,
            )
            # Get a master connection from Sentinel
            r = sentinel.master_for(redis_config["service"])
            r.ping() # Verify connection
            log.info(f"Successfully connected to Redis master via Sentinel: {redis_config['service']}")
            return r
        else:
            # Standard Redis connection
            log.info(f"Connecting via standard Redis URL: {redis_url}")
            r = redis.Redis.from_url(redis_url, decode_responses=decode_responses)
            r.ping() # Verify connection
            log.info("Successfully connected to standard Redis.")
            return r
    except redis.exceptions.ConnectionError as e:
        log.error(f"Redis ConnectionError: {e}")
        raise
    except redis.exceptions.AuthenticationError as e:
        log.error(f"Redis AuthenticationError: {e}")
        raise
    except Exception as e:
        log.error(f"Failed to connect to Redis. URL: '{redis_url}', Sentinels: {redis_sentinels}. Error: {e}", exc_info=True)
        raise


def get_sentinels_from_env(sentinel_hosts_env, sentinel_port_env):
    if sentinel_hosts_env:
        sentinel_hosts = sentinel_hosts_env.split(",")
        sentinel_port = int(sentinel_port_env)
        return [(host, sentinel_port) for host in sentinel_hosts]
    return []


def get_sentinel_url_from_env(redis_url, sentinel_hosts_env, sentinel_port_env):
    redis_config = parse_redis_service_url(redis_url)
    username = redis_config["username"] or ""
    password = redis_config["password"] or ""
    auth_part = ""
    if username or password:
        auth_part = f"{username}:{password}@"
    hosts_part = ",".join(
        f"{host}:{sentinel_port_env}" for host in sentinel_hosts_env.split(",")
    )
    return f"redis+sentinel://{auth_part}{hosts_part}/{redis_config['db']}/{redis_config['service']}"
