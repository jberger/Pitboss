-- 1 up

CREATE TABLE IF NOT EXISTS pitboss_workers (
  id BIGSERIAL PRIMARY KEY,
  host TEXT NOT NULL,
  pid INT NOT NULL,
  active BOOLEAN DEFAULT 't',
  started TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  notified TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pitboss_queue (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  batches BIGINT[] DEFAULT '{}'::BIGINT[],
  enabled BOOLEAN DEFAULT 't',
  last_job_completed BIGINT,
  last_job_completed_at TIMESTAMP WITH TIME ZONE,
  last_batch_completed BIGINT,
  last_batch_finished BIGINT,
  last_batch_failed BIGINT,
  job_interval INTERVAL NOT NULL DEFAULT '0s'
);

CREATE TABLE IF NOT EXISTS pitboss_locks (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  exclusive BOOLEAN DEFAULT 'f',
  holders BIGINT[] DEFAULT '{}'::BIGINT[]
);

CREATE TABLE IF NOT EXISTS pitboss_tags (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  enabled BOOLEAN DEFAULT 't'
);

CREATE TABLE IF NOT EXISTS pitboss_batch (
  id BIGSERIAL PRIMARY KEY,
  queue TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'inactive',
  description TEXT,
  previous BIGINT,
  log_tags JSONB DEFAULT '{}',
  exclusive TEXT[] DEFAULT '{}'::TEXT[],
  shared TEXT[] DEFAULT '{}'::TEXT[],
  tags TEXT[] DEFAULT '{}'::TEXT[],
  job_order BIGINT[] DEFAULT '{}'::BIGINT[],
  created TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  started TIMESTAMP WITH TIME ZONE,
  finished TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS pitboss_jobs (
  id BIGSERIAL PRIMARY KEY,
  batch BIGINT NOT NULL REFERENCES pitboss_batch ON DELETE CASCADE,
  task TEXT NOT NULL,
  args JSONB DEFAULT '[]'::JSONB,
  state TEXT DEFAULT 'inactive',
  description TEXT,
  log_tags JSONB DEFAULT '{}',
  result JSONB,
  created TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  started TIMESTAMP WITH TIME ZONE,
  finished TIMESTAMP WITH TIME ZONE,
  expires TIMESTAMP WITH TIME ZONE,
  not_until TIMESTAMP WITH TIME ZONE,
  worker BIGINT REFERENCES pitboss_workers ON DELETE CASCADE,
  detached BOOLEAN NOT NULL DEFAULT 'f'
);

CREATE TABLE IF NOT EXISTS pitboss_job_progress (
  id BIGSERIAL PRIMARY KEY,
  job BIGINT NOT NULL REFERENCES pitboss_jobs ON DELETE CASCADE,
  posted TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  value INT,
  note TEXT,
  data JSONB
);

-- there is no CREATE OR REPLACE TYPE so let's be defensive here
DROP TYPE IF EXISTS pitboss_job CASCADE;
CREATE TYPE pitboss_job AS (
  -- all values from pitboss_jobs
  id BIGINT,
  batch BIGINT,
  task TEXT,
  args JSONB,
  description TEXT,
  state TEXT,
  result JSONB,
  created TIMESTAMP WITH TIME ZONE,
  started TIMESTAMP WITH TIME ZONE,
  finished TIMESTAMP WITH TIME ZONE,
  expires TIMESTAMP WITH TIME ZONE,
  not_until TIMESTAMP WITH TIME ZONE,
  worker BIGINT,
  detached BOOLEAN,

  -- additional fields
  last_progress TIMESTAMP WITH TIME ZONE,
  log_tags JSONB
);

CREATE OR REPLACE FUNCTION
  pitboss_maybe_notify(_channel TEXT, _payload TEXT, OUT _success BOOLEAN)
  AS $$
  BEGIN
    BEGIN
      PERFORM pg_notify(_channel, _payload);
      _success := 't';
    EXCEPTION WHEN invalid_parameter_value THEN
      RAISE WARNING 'Pitboss notification sent to channel %s was too long.', _channel USING HINT = _channel, DETAIL = _payload;
      _success := 'f';
    END;
  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_get_job(_id BIGINT, OUT _job pitboss_job)
  RETURNS pitboss_job
  AS $$
  BEGIN
    SELECT
      job.id,
      job.batch,
      job.task,
      job.args,
      job.description,
      job.state,
      job.result,
      job.created,
      job.started,
      job.finished,
      job.expires,
      job.not_until,
      job.worker,
      job.detached,

      (
        SELECT progress.posted
        FROM pitboss_job_progress progress
        WHERE progress.job = job.id
        ORDER BY progress.posted DESC
        LIMIT 1
      ) AS last_progress,

      (
        batch.log_tags ||
        job.log_tags   ||
        jsonb_build_object('job', job.id, 'batch', job.batch)
      ) AS log_tags

    INTO _job
    FROM pitboss_jobs job
    INNER JOIN pitboss_batch batch ON job.batch = batch.id
    WHERE job.id = _id
    LIMIT 1;
  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_release_locks(_id BIGINT)
  RETURNS BOOLEAN
  AS $$
  DECLARE
    _batch pitboss_batch%ROWTYPE;
  BEGIN
    SELECT *
    INTO _batch
    FROM pitboss_batch
    WHERE id=_id;

    IF NOT FOUND THEN
      RETURN 't';
    END IF;

    IF _batch.state='active' THEN
      RETURN 'f';
    END IF;

    -- release exclusive locks
    UPDATE pitboss_locks
    SET exclusive='f', holders='{}'::BIGINT[]
    WHERE name=ANY(_batch.exclusive)
      AND exclusive
      AND _batch.id=ALL(holders);

    -- release shared locks
    UPDATE pitboss_locks
    SET holders = array_remove(holders, _batch.id)
    WHERE name=ANY(_batch.shared)
      AND NOT exclusive;

    RETURN 't';
  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_close_batch(_id BIGINT, OUT ret TEXT)
  RETURNS text
  AS $$
  DECLARE
    _batch pitboss_batch%ROWTYPE;
  BEGIN
    -- determine final state
    PERFORM
    FROM pitboss_jobs
    WHERE batch=_id
      AND state != 'finished';

    IF FOUND THEN
      ret := 'failed';
    ELSE
      ret := 'finished';
    END IF;

    -- close the batch
    UPDATE pitboss_batch
    INTO _batch
    SET state=ret, finished=NOW()
    WHERE id=_id
    RETURNING *;

    -- remove locks
    PERFORM pitboss_release_locks(_id);

    -- remove the batch from the queue
    UPDATE pitboss_queue
    SET
      batches = array_remove(batches, _id),
      last_batch_completed = _id,
      last_batch_finished = CASE WHEN ret = 'finished' THEN _id ELSE last_batch_finished END,
      last_batch_failed   = CASE WHEN ret = 'failed'   THEN _id ELSE last_batch_failed   END
    WHERE name=_batch.queue;

  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_update_job(_id BIGINT, _final TEXT, _result JSONB)
  RETURNS SETOF pitboss_job
  AS $$
  DECLARE
    _batch RECORD;
    _now TIMESTAMP WITH TIME ZONE;
  BEGIN
    -- lock the batch
    SELECT j.batch as id, b.queue
    INTO _batch
    FROM pitboss_jobs j
    INNER JOIN pitboss_batch b ON b.id=j.batch
    WHERE j.id=_id
    FOR UPDATE OF j;

    IF NOT FOUND THEN
      RAISE 'job % was not found', _id;
    END IF;

    _now := NOW();

    -- mark job as done
    UPDATE pitboss_jobs
    SET
      state    = _final,
      finished = _now,
      result   = _result
    WHERE id=_id
      AND state IN ('inactive', 'active');

    IF NOT FOUND THEN
      RETURN;
    END IF;

    RETURN QUERY SELECT * FROM pitboss_get_job(_id);

    UPDATE pitboss_queue
    SET last_job_completed=_id,
      last_job_completed_at=_now
    WHERE name=_batch.queue;

    -- a failed job fails the batch
    IF _final='failed' THEN
      PERFORM pitboss_close_batch(_batch.id);
      RETURN;
    END IF;

    -- check to see if the batch is complete
    PERFORM
    FROM pitboss_jobs
    WHERE batch=_batch.id
      AND state='inactive';

    -- mark it complete if so
    IF NOT FOUND THEN
      PERFORM pitboss_close_batch(_batch.id);
    END IF;

  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_acquire_locks(
    _id BIGINT,
    _exclusive TEXT[],
    _shared TEXT[],
    OUT ret BOOLEAN
  )
  AS $$
  DECLARE
    _both TEXT[];
    _count INT;
  BEGIN
    _both = _exclusive || _shared;

    -- return early if no locks are requested
    IF array_length(_both, 1) IS NULL THEN
      ret := 't';
      RETURN;
    END IF;

    -- check to see if the locks are available
    PERFORM
    FROM pitboss_locks
    WHERE
      NOT exclusive
      AND (
        name=ANY(_shared)
        OR (name=ANY(_exclusive) AND array_length(holders, 1) IS NULL)
      )
    FOR UPDATE SKIP LOCKED;

    -- check to see that ALL the locks were selected
    GET DIAGNOSTICS _count = ROW_COUNT;
    IF _count != array_length(_both, 1) THEN
      ret := 'f';
      RETURN;
    END IF;

    -- mark the exclusive locks
    UPDATE pitboss_locks
    SET exclusive='t', holders=ARRAY[_id]
    WHERE name=ANY(_exclusive);

    -- mark the shared locks
    UPDATE pitboss_locks
    SET holders = holders || ARRAY[_id]
    WHERE name=ANY(_shared);

    ret := 't';
  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_check_rate_limit(_name TEXT)
  RETURNS BOOLEAN
  AS $$
  DECLARE
    _queue pitboss_queue%ROWTYPE;
  BEGIN
    SELECT *
    INTO _queue
    FROM pitboss_queue
    WHERE name=_name;

    IF NOT FOUND THEN
      RAISE 'queue % not found!', _name;
    END IF;

    IF _queue.job_interval='0s' OR _queue.last_job_completed_at IS NULL THEN
      RETURN 't';
    END IF;

    RETURN NOW() >= _queue.last_job_completed_at + _queue.job_interval;

  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_dequeue_from_batch(_worker_id BIGINT, _batch_id BIGINT, _time TIMESTAMP WITH TIME ZONE)
  RETURNS SETOF pitboss_job
  AS $$
  DECLARE
    _job_id BIGINT;
    _job_order BIGINT[];
    _not_until TIMESTAMP WITH TIME ZONE;
  BEGIN
    -- worker id is not required (yet)
    IF _worker_id IS NOT NULL THEN

      -- check that the worker id is still active
      -- lock the worker row if it is active
      PERFORM
      FROM pitboss_workers
      WHERE id=_worker_id
        AND active
      FOR UPDATE;

      -- if an active worker is not found then return early
      IF NOT FOUND THEN
        RETURN;
      END IF;
    END IF;

    SELECT job_order
    INTO _job_order
    FROM pitboss_batch
    WHERE id=_batch_id;

    -- check job expiration in the batch
    SELECT id
    INTO _job_id
    FROM pitboss_jobs
    WHERE batch=_batch_id
      AND state='inactive'
      AND expires IS NOT NULL
      AND expires <= _time
    ORDER BY ARRAY_POSITION(_job_order, id)
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      PERFORM pitboss_update_job(_job_id, 'failed', to_jsonb('expiration time reached'::TEXT));
      RETURN;
    END IF;


    SELECT id, not_until
    INTO _job_id, _not_until
    FROM pitboss_jobs
    WHERE batch=_batch_id
      AND state='inactive'
      AND NOT EXISTS (
        SELECT 1
        FROM pitboss_jobs
        WHERE batch=_batch_id
          AND state='active'
      )
    ORDER BY ARRAY_POSITION(_job_order, id)
    LIMIT 1
    FOR UPDATE;

    -- check that the first candidate job isn't delayed
    IF ((_not_until IS NULL) OR (_time >= _not_until)) THEN
      -- update the job and return it, being extra careful that it is still a candidate
      UPDATE pitboss_jobs
      SET state='active', started=_time, worker=_worker_id
      WHERE id=_job_id;

      IF FOUND THEN
        RETURN QUERY SELECT * FROM pitboss_get_job(_job_id);
      END IF;
    END IF;

  END
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_dequeue(_worker_id BIGINT)
  RETURNS SETOF pitboss_job
  AS $$
  DECLARE
    batch pitboss_batch%ROWTYPE;
    _now TIMESTAMP WITH TIME ZONE;
  BEGIN
    -- try active queue/batch where no jobs in the batch are currently running
    FOR batch IN
      SELECT b.*
      FROM pitboss_batch b
      INNER JOIN pitboss_queue q ON q.batches[1]=b.id
      WHERE q.enabled
        AND b.state='active'
        AND NOT EXISTS (
          SELECT 1
          FROM pitboss_tags t
          WHERE t.name=ANY(b.tags)
            AND NOT t.enabled
        )
        AND NOT EXISTS (
          SELECT 1
          FROM pitboss_jobs j
          WHERE j.batch=b.id
            AND j.state='active'
        )
        AND pitboss_check_rate_limit(b.queue)
      ORDER BY created ASC
      LIMIT 1
      FOR UPDATE OF b
      SKIP LOCKED
    LOOP

      -- in this batch attempt to dequeue a job
      RETURN QUERY SELECT * FROM pitboss_dequeue_from_batch(_worker_id, batch.id, NOW());

      -- if a job was dequeued then return it
      IF FOUND THEN
        RETURN;
      END IF;

      -- otherwise try another batch
    END LOOP;

    -- no open batches had jobs ready, try finding a batch to open
    FOR batch IN
      SELECT b.*
      FROM pitboss_queue q
      INNER JOIN pitboss_batch b ON q.batches[1]=b.id
      WHERE q.enabled
        AND b.state='inactive'
        AND NOT EXISTS (
          SELECT 1
          FROM pitboss_tags t
          WHERE t.name=ANY(b.tags)
            AND NOT t.enabled
        )
        AND pitboss_check_rate_limit(q.name)
      ORDER BY b.created ASC
      FOR UPDATE OF b
      SKIP LOCKED
    LOOP
      -- try to acquire the locks
      CONTINUE WHEN NOT pitboss_acquire_locks(batch.id, batch.exclusive, batch.shared);

      _now = NOW();

      /* try to mark job as active and set if for return,
         note that batch is not yet open */
      RETURN QUERY SELECT * FROM pitboss_dequeue_from_batch(_worker_id, batch.id, _now);

      -- if a job was not found release locks and try another batch
      IF NOT FOUND THEN
        PERFORM pitboss_release_locks(batch.id);
        CONTINUE;
      END IF;

      -- if a job was found mark the bach as open and return the job
      UPDATE pitboss_batch
      SET state='active', started=_now
      WHERE id=batch.id;

      RETURN;
    END LOOP;
  END;
  $$ language plpgsql;

CREATE OR REPLACE FUNCTION
  pitboss_notify_job()
  RETURNS TRIGGER
  AS $$
    DECLARE
      _batch pitboss_batch%ROWTYPE;
      _payload TEXT;
    BEGIN
      SELECT *
      INTO _batch
      FROM pitboss_batch
      WHERE id=NEW.batch
      LIMIT 1;
      _payload = json_build_object(
        'type', 'job',
        'id',    NEW.id,
        'description', NEW.description,
        'batch_description', _batch.description,
        'state', NEW.state,
        'task',  NEW.task,
        'batch', NEW.batch,
        'queue', _batch.queue,
        'tags', to_json(_batch.tags),
        'log_tags', (
          _batch.log_tags ||
          NEW.log_tags   ||
          jsonb_build_object('job', NEW.id, 'batch', NEW.batch)
        )
      )::TEXT;
      PERFORM pitboss_maybe_notify('pitboss.queue', _payload);
      PERFORM pitboss_maybe_notify('pitboss.queue.' || _batch.queue, _payload);
      RETURN NULL;
    END;
  $$ language plpgsql;


CREATE TRIGGER pitboss_notify_job_trigger
  AFTER INSERT OR UPDATE OF state ON pitboss_jobs
  FOR EACH ROW EXECUTE PROCEDURE pitboss_notify_job();

CREATE OR REPLACE FUNCTION
  pitboss_notify_batch()
  RETURNS TRIGGER
  AS $$
    DECLARE
      _payload TEXT;
    BEGIN
      _payload = json_build_object(
        'type',  'batch',
        'id',    NEW.id,
        'description', NEW.description,
        'state', NEW.state,
        -- TODO tasks would say empty when first enqueued, not sure that's worth it
        -- 'tasks', (SELECT json_agg(task ORDER BY created) FROM pitboss_jobs WHERE batch=NEW.id),
        'queue', NEW.queue,
        'tags', to_json(NEW.tags),
        'log_tags', (
          NEW.log_tags ||
          jsonb_build_object('batch', NEW.id)
        )
      )::TEXT;
      PERFORM pitboss_maybe_notify('pitboss.queue', _payload);
      PERFORM pitboss_maybe_notify('pitboss.queue.' || NEW.queue, _payload);
      RETURN NULL;
    END;
  $$ language plpgsql;


CREATE TRIGGER pitboss_notify_batch_trigger
  AFTER INSERT OR UPDATE OF state ON pitboss_batch
  FOR EACH ROW EXECUTE PROCEDURE pitboss_notify_batch();

CREATE OR REPLACE FUNCTION
  pitboss_notify_queue()
  RETURNS TRIGGER
  AS $$
    DECLARE
      _payload TEXT;
      _new_length INT;
      _batches BIGINT[];
    BEGIN
      /*
       * In the case where the queue gets huge, the list of jobs might overwhelm the 8k notification limit.
       * As such. truncate the returned list of batches to 50 and include a count of the total
       */

      _new_length := COALESCE(array_length(NEW.batches, 1), 0);
      _batches := NEW.batches[1:50];

      IF TG_OP = 'INSERT' THEN
        -- new queue
        _payload = json_build_object(
          'type',   'queue',
          'id',     NEW.id,
          'queue',  NEW.name,
          'action', 'create'
        )::TEXT;
        PERFORM pitboss_maybe_notify('pitboss.queue', _payload);
        -- this meta notifier informs of new queues only
        PERFORM pitboss_maybe_notify('pitboss.meta.queue', _payload);
        PERFORM pitboss_maybe_notify('pitboss.queue.' || NEW.name, _payload);
        _payload = NULL;

        -- check for items, emit enqueue as well
        IF _new_length > 0 THEN
          _payload = json_build_object(
            'type',  'queue',
            'id',     NEW.id,
            'queue',  NEW.name,
            'action', 'enqueue',
            'batch',  NEW.batches[array_upper(NEW.batches, 1)],
            'state',  _batches,
            'total',  _new_length
          )::TEXT;
        END IF;
      ELSIF _new_length > COALESCE(array_length(OLD.batches, 1), 0) THEN
        -- enqueue batch
        _payload = json_build_object(
          'type',  'queue',
          'id',     NEW.id,
          'queue',  NEW.name,
          'action', 'enqueue',
          'batch',  NEW.batches[array_upper(NEW.batches, 1)],
          'state',  _batches,
          'total',  _new_length
        )::TEXT;
      ELSIF _new_length < COALESCE(array_length(OLD.batches, 1), 0) THEN
        -- dequeue batch
        _payload = json_build_object(
          'type',  'queue',
          'id',     NEW.id,
          'queue',  NEW.name,
          'action', 'dequeue',
          'batch',  OLD.batches[1],
          'state',  _batches,
          'total',  _new_length
        )::TEXT;
      END IF;

      IF _payload IS NOT NULL THEN
        PERFORM pitboss_maybe_notify('pitboss.queue', _payload);
        PERFORM pitboss_maybe_notify('pitboss.queue.' || NEW.name, _payload);
      END IF;
      RETURN NULL;
    END;
  $$ language plpgsql;

CREATE TRIGGER pitboss_notify_queue_trigger
  AFTER INSERT OR UPDATE OF batches ON pitboss_queue
  FOR EACH ROW EXECUTE PROCEDURE pitboss_notify_queue();

CREATE OR REPLACE FUNCTION
  pitboss_notify_job_progress()
  RETURNS TRIGGER
  AS $$
    DECLARE
      _job RECORD;
      _payload TEXT;
    BEGIN
      SELECT
        j.*,
        (
          SELECT b.queue
          FROM pitboss_batch b
          WHERE b.id = j.batch
          LIMIT 1
        )
      INTO _job
      FROM pitboss_jobs j
      WHERE j.id=NEW.job
      LIMIT 1;
      _payload = json_build_object(
        'type', 'progress',
        'id',    NEW.id,
        'job',   NEW.job,
        'state', _job.state,
        'task',  _job.task,
        'batch', _job.batch,
        'queue', _job.queue,
        'posted', NEW.posted,
        'value', NEW.value,
        'has_note', NEW.note IS NOT NULL,
        'has_data', NEW.data IS NOT NULL
      )::TEXT;
      PERFORM pitboss_maybe_notify('pitboss.queue', _payload);
      PERFORM pitboss_maybe_notify('pitboss.queue.' || _job.queue, _payload);
      RETURN NULL;
    END;
  $$ language plpgsql;

CREATE TRIGGER pitboss_notify_job_progress_trigger
  AFTER INSERT ON pitboss_job_progress
  FOR EACH ROW EXECUTE PROCEDURE pitboss_notify_job_progress();

CREATE INDEX pitboss_batch_find_batches ON pitboss_batch (queue, state, created ASC, created DESC, id ASC, id DESC);
CREATE INDEX pitboss_jobs_batch_job_aggregate ON pitboss_jobs (id, batch, created);
CREATE INDEX pitboss_jobs_fkey ON pitboss_jobs (batch);
CREATE INDEX pitboss_job_progress_fkey ON pitboss_job_progress (job);

-- 1 down

DROP TRIGGER IF EXISTS pitboss_notify_job_trigger ON pitboss_jobs;
DROP TRIGGER IF EXISTS pitboss_notify_batch_trigger ON pitboss_batch;
DROP TRIGGER IF EXISTS pitboss_notify_queue_trigger ON pitboss_queue;
DROP TRIGGER IF EXISTS pitboss_notify_job_progress_trigger ON pitboss_job_progress;

DROP TABLE IF EXISTS pitboss_workers CASCADE;
DROP TABLE IF EXISTS pitboss_queue CASCADE;
DROP TABLE IF EXISTS pitboss_locks CASCADE;
DROP TABLE IF EXISTS pitboss_tags CASCADE;
DROP TABLE IF EXISTS pitboss_batch CASCADE;
DROP TABLE IF EXISTS pitboss_jobs CASCADE;
DROP TABLE IF EXISTS pitboss_job_progress CASCADE;

DROP TYPE IF EXISTS pitboss_job CASCADE;

DROP FUNCTION IF EXISTS pitboss_maybe_notify(TEXT, TEXT, OUT BOOLEAN);
DROP FUNCTION IF EXISTS pitboss_get_job(BIGINT, OUT pitboss_job);
DROP FUNCTION IF EXISTS pitboss_release_locks(BIGINT);
DROP FUNCTION IF EXISTS pitboss_notify_job();
DROP FUNCTION IF EXISTS pitboss_notify_batch();
DROP FUNCTION IF EXISTS pitboss_notify_queue();
DROP FUNCTION IF EXISTS pitboss_notify_job_progress();
DROP FUNCTION IF EXISTS pitboss_check_rate_limit(TEXT);
DROP FUNCTION IF EXISTS pitboss_close_batch(BIGINT, OUT TEXT);
DROP FUNCTION IF EXISTS pitboss_update_job(BIGINT, TEXT, JSONB, OUT pitboss_job);
DROP FUNCTION IF EXISTS pitboss_acquire_locks(BIGINT, TEXT[], TEXT[], OUT BOOLEAN);
DROP FUNCTION IF EXISTS pitboss_dequeue_from_batch(_worker_id BIGINT, _batch_id BIGINT, _time TIMESTAMP WITH TIME ZONE, OUT pitboss_job);
DROP FUNCTION IF EXISTS pitboss_dequeue(BIGINT);

DROP INDEX IF EXISTS pitboss_batch_find_batches;
DROP INDEX IF EXISTS pitboss_jobs_batch_job_aggregate;
DROP INDEX IF EXISTS pitboss_jobs_fkey;
DROP INDEX IF EXISTS pitboss_job_progress_fkey;

