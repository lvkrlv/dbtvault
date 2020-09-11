{#- Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
-#}
{%- macro eff_sat(src_pk, src_dfk, src_sfk, src_start_date, src_end_date, src_eff, src_ldts, src_source, link_model, source_model) -%}

    {{- adapter_macro('dbtvault.eff_sat', src_pk=src_pk, src_dfk=src_dfk, src_sfk=src_sfk,
                      src_start_date=src_start_date, src_end_date=src_end_date,
                      src_eff=src_eff, src_ldts=src_ldts, src_source=src_source,
                      link_model=link_model, source_model=source_model) -}}

{%- endmacro %}

{%- macro default__eff_sat(src_pk, src_dfk, src_sfk, src_start_date, src_end_date, src_eff, src_ldts, src_source, link_model, source_model) -%}

{%- set source_cols = dbtvault.expand_column_list(columns=[src_pk, src_dfk, src_sfk, src_start_date, src_end_date, src_eff, src_ldts, src_source]) -%}

{%- set structure_cols = dbtvault.expand_column_list(columns=[src_pk, src_start_date, src_end_date, src_eff, src_ldts, src_source]) -%}

-- Generated by dbtvault.
-- depends_on: {{ ref(link_model) }}

WITH source_data AS (

    SELECT *
    FROM {{ ref(source_model) }}
    {% if dbtvault.is_vault_insert_by_period() or model.config.materialized == 'vault_insert_by_period' %}
        WHERE __PERIOD_FILTER__
    {% endif %}
),
{%- if load_relation(this) is none %}
    records_to_insert AS (
        SELECT {{ dbtvault.alias_all(structure_cols, 'e') }}
        FROM source_data AS e
    )
{%- else %}
    latest_eff AS
    (
        SELECT {{ dbtvault.alias_all(structure_cols, 'b') }},
               ROW_NUMBER() OVER (
                    PARTITION BY b.{{ src_pk }}
                    ORDER BY b.{{ src_ldts }} DESC
               ) AS row_number
        FROM {{ this }} AS b
    ),
    latest_open_eff AS
    (
        SELECT {{ dbtvault.alias_all(structure_cols, 'a') }}
        FROM latest_eff AS a
        WHERE TO_DATE(a.{{ src_end_date }}) = TO_DATE('9999-12-31')
        AND a.row_number = 1
    ),
    stage_slice AS
    (
        SELECT {{ dbtvault.alias_all(source_cols, 'stage') }}
        FROM source_data AS stage
{#        WHERE {{ dbtvault.multikey(src_dfk, prefix='stage', condition='IS NOT NULL') }}#}
{#        AND {{ dbtvault.multikey(src_sfk, prefix='stage', condition='IS NOT NULL') }}#}
    ),
    open_links AS (
        SELECT c.*
        FROM {{ ref(link_model) }} AS c
        INNER JOIN latest_open_eff AS d
        ON c.{{ src_pk }} = d.{{ src_pk }}
    ),
    links_to_end_date AS (
        SELECT a.*
        FROM open_links AS a
        LEFT JOIN stage_slice AS b
        ON {{ dbtvault.multikey(src_dfk, prefix=['a', 'b'], condition='=') }}
        WHERE {{ dbtvault.multikey(src_sfk, prefix='b', condition='IS NULL') }}
        OR {{ dbtvault.multikey(src_sfk, prefix=['a', 'b'], condition='<>') }}
    ),
    new_open_records AS (
        SELECT DISTINCT
            {{ dbtvault.alias_all(structure_cols, 'stage') }}
        FROM stage_slice AS stage
        LEFT JOIN latest_open_eff AS e
        ON stage.{{ src_pk }} = e.{{ src_pk }}
        WHERE e.{{ src_pk }} IS NULL
        AND {{ dbtvault.multikey(src_dfk, prefix='stage', condition='IS NOT NULL') }}
        AND {{ dbtvault.multikey(src_sfk, prefix='stage', condition='IS NOT NULL') }}
    ),
    new_end_dated_records AS (
        SELECT DISTINCT
            h.{{ src_pk }}, g.{{ src_dfk }}, h.EFFECTIVE_FROM AS {{ src_start_date }}, h.{{ src_source }}
        FROM latest_open_eff AS h
        INNER JOIN links_to_end_date AS g
        ON g.{{ src_pk }} = h.{{ src_pk }}
    ),
    amended_end_dated_records AS (
        SELECT DISTINCT
            a.CUSTOMER_ORDER_PK, a.START_DATE,
            stage.EFFECTIVE_FROM AS END_DATE, stage.EFFECTIVE_FROM, stage.LOAD_DATE,
            a.SOURCE
        FROM new_end_dated_records AS a
        INNER JOIN stage_slice AS stage
        ON {{ dbtvault.multikey(src_dfk, prefix=['stage', 'a'], condition='=') }}
    ),
    records_to_insert AS (
        SELECT * FROM new_open_records
        UNION
        SELECT * FROM amended_end_dated_records
    )
{%- endif %}

SELECT * FROM records_to_insert
{%- endmacro -%}