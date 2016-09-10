--create schema
CREATE SCHEMA IF NOT EXISTS sch_chameleon;



CREATE TABLE sch_chameleon.t_replica_batch
(
  i_id_batch bigserial NOT NULL,
  t_binlog_name text,
  i_binlog_position integer,
  b_started boolean NOT NULL DEFAULT False,
  b_processed boolean NOT NULL DEFAULT False,
  b_replayed boolean NOT NULL DEFAULT False,
  ts_created timestamp without time zone NOT NULL DEFAULT clock_timestamp(),
  ts_processed timestamp without time zone ,
  ts_replayed timestamp without time zone ,
  v_log_table character varying(100) NOT NULL,
  CONSTRAINT pk_t_batch PRIMARY KEY (i_id_batch)
)
WITH (
  OIDS=FALSE
);

CREATE UNIQUE INDEX idx_t_replica_batch_binlog_name_position 
	ON sch_chameleon.t_replica_batch (t_binlog_name,i_binlog_position);

CREATE UNIQUE INDEX idx_t_replica_batch_ts_created
	ON sch_chameleon.t_replica_batch (ts_created);

CREATE TABLE IF NOT EXISTS sch_chameleon.t_log_replica
(
  i_id_event bigserial NOT NULL,
  i_id_batch bigserial NOT NULL,
  v_table_name character varying(100) NOT NULL,
  v_schema_name character varying(100) NOT NULL,
  v_binlog_event character varying(100) NOT NULL,
  t_binlog_name text,
  i_binlog_position integer,
  ts_event_datetime timestamp without time zone NOT NULL DEFAULT clock_timestamp(),
  jsb_event_data jsonb,
  CONSTRAINT pk_log_replica PRIMARY KEY (i_id_event),
  CONSTRAINT fk_replica_batch FOREIGN KEY (i_id_batch) 
	REFERENCES  sch_chameleon.t_replica_batch (i_id_batch)
	ON UPDATE RESTRICT ON DELETE CASCADE
)
WITH (
  OIDS=FALSE
);

CREATE TABLE IF NOT EXISTS sch_chameleon.t_log_replica_1 
(
CONSTRAINT pk_log_replica_1 PRIMARY KEY (i_id_event),
  CONSTRAINT fk_replica_batch_1 FOREIGN KEY (i_id_batch) 
	REFERENCES  sch_chameleon.t_replica_batch (i_id_batch)
	ON UPDATE RESTRICT ON DELETE CASCADE
)
INHERITS (sch_chameleon.t_log_replica)
;

CREATE TABLE IF NOT EXISTS sch_chameleon.t_log_replica_2
(
CONSTRAINT pk_log_replica_2 PRIMARY KEY (i_id_event),
  CONSTRAINT fk_replica_batch_2 FOREIGN KEY (i_id_batch) 
	REFERENCES  sch_chameleon.t_replica_batch (i_id_batch)
	ON UPDATE RESTRICT ON DELETE CASCADE
)
INHERITS (sch_chameleon.t_log_replica)
;

CREATE TABLE sch_chameleon.t_replica_tables
(
  i_id_table bigserial NOT NULL,
  v_table_name character varying(100) NOT NULL,
  v_schema_name character varying(100) NOT NULL,
  v_table_pkey character varying(100)[] NOT NULL,
  CONSTRAINT pk_t_replica_tables PRIMARY KEY (i_id_table)
)
WITH (
  OIDS=FALSE
);

CREATE UNIQUE INDEX idx_t_replica_tables_table_schema
	ON sch_chameleon.t_replica_tables (v_table_name,v_schema_name);


CREATE OR REPLACE FUNCTION sch_chameleon.fn_process_batch()
RETURNS VOID AS
$BODY$
	DECLARE
		v_r_rows	record;
		v_t_fields	text[];
		v_t_values	text[];
		v_t_sql_rep	text;
		v_t_pkey	text;
		v_t_vals	text;
		v_t_update	text;
		v_t_ins_fld	text;
		v_t_ins_val	text;
	BEGIN
		FOR v_r_rows IN WITH t_batch AS
					(
						SELECT 
							i_id_batch 
						FROM 
							sch_chameleon.t_replica_batch  
						WHERE 
								b_started 
							AND 	b_processed 
						ORDER BY 
							ts_created 
						LIMIT 1
					),
				t_events AS
					(
						SELECT 
							bat.i_id_batch,
							log.v_table_name,
							log.v_schema_name,
							log.v_binlog_event,
							log.jsb_event_data,
							replace(array_to_string(tab.v_table_pkey,','),'"','') as t_pkeys,
							array_length(tab.v_table_pkey,1) as i_pkeys
						FROM 
							sch_chameleon.t_log_replica  log
							INNER JOIN sch_chameleon.t_replica_tables tab
								ON
										tab.v_table_name=log.v_table_name
									AND 	tab.v_schema_name=log.v_schema_name
								INNER JOIN t_batch bat
								ON	bat.i_id_batch=log.i_id_batch
							
						ORDER BY ts_event_datetime
					)
				SELECT
					i_id_batch,
					v_table_name,
					v_schema_name,
					v_binlog_event,
					jsb_event_data,
					string_to_array(t_pkeys,',') as v_table_pkey,
					t_pkeys,
					i_pkeys
				FROM
					t_events
			LOOP

			SELECT 
				array_agg(key) evt_fields,
				array_agg(value) evt_values
				INTO
					v_t_fields,
					v_t_values
			FROM (
				SELECT 
					key ,
					value
				FROM 
					jsonb_each_text(v_r_rows.jsb_event_data) js_event
			     ) js_dat
			;

			
			WITH 	t_jsb AS
				(
					SELECT 
						v_r_rows.jsb_event_data jsb_event_data,
						v_r_rows.v_table_pkey v_table_pkey
				),
				t_subscripts AS
				(
					SELECT 
						generate_subscripts(v_table_pkey,1) sub
					FROM 
						t_jsb
				)
			SELECT 
				array_to_string(v_table_pkey,','),
				array_to_string(array_agg((jsb_event_data->>v_table_pkey[sub])::text),',') as pk_value
				INTO 
					v_t_pkey,
					v_t_vals

			FROM
				t_subscripts,t_jsb
			GROUP BY v_table_pkey
			;
			
			RAISE DEBUG '% % % % % %',v_r_rows.v_table_name,
					v_r_rows.v_schema_name,
					v_r_rows.v_table_pkey,
					v_r_rows.v_binlog_event,v_t_fields,v_t_values;
			IF v_r_rows.v_binlog_event='delete'
			THEN
				v_t_sql_rep=format('DELETE FROM %I.%I WHERE (%I)=(%s) ;',
							v_r_rows.v_schema_name,
							v_r_rows.v_table_name,
							v_t_pkey,
							v_t_vals
						);
				RAISE DEBUG '%',v_t_sql_rep;
			ELSEIF v_r_rows.v_binlog_event='update'
			THEN 
				SELECT 
					array_to_string(array_agg(format('%I=%L',t_field,t_value)),',') 
					INTO
						v_t_update
				FROM
				(
					SELECT 
						unnest(v_t_fields) t_field, 
						unnest(v_t_values) t_value
				) t_val
				;

				v_t_sql_rep=format('UPDATE  %I.%I 
								SET
									%s
							WHERE (%I)=(%s) ;',
							v_r_rows.v_schema_name,
							v_r_rows.v_table_name,
							v_t_update,
							v_t_pkey,
							v_t_vals
						);
				RAISE DEBUG '%',v_t_sql_rep;
			ELSEIF v_r_rows.v_binlog_event='insert'
			THEN
				SELECT 
					array_to_string(array_agg(format('%I',t_field)),',') t_field,
					array_to_string(array_agg(format('%L',t_value)),',') t_value
					INTO
						v_t_ins_fld,
						v_t_ins_val
				FROM
				(
					SELECT 
						unnest(v_t_fields) t_field, 
						unnest(v_t_values) t_value
				) t_val
				;
				v_t_sql_rep=format('INSERT INTO  %I.%I 
								(
									%s
								)
							VALUES
								(
									%s
								)
							;',
							v_r_rows.v_schema_name,
							v_r_rows.v_table_name,
							v_t_ins_fld,
							v_t_ins_val
							
						);

				RAISE DEBUG '%',v_t_sql_rep;
			END IF;
			EXECUTE v_t_sql_rep;
			
			

		END LOOP;
		DELETE FROM sch_chameleon.t_replica_batch  
		WHERE
			i_id_batch=v_r_rows.i_id_batch
		;
	
	END;
$BODY$
LANGUAGE plpgsql;