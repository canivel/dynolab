from dyno.pool.worker_app import main
import sys

if __name__ == '__main__':
    if '--pair' in sys.argv:
        from dyno.pool.pair_app import main
    raise SystemExit(main())
