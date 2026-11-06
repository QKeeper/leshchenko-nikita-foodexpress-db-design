-- db/schema/03_api.sql
-- Прикладные процедуры, функции и аналитические отчеты
-- (FOOD-104, FOOD-106, FOOD-107, FOOD-108)

-- 1. FOOD-104: Процедура добавления блюда (add_product)

CREATE OR REPLACE PROCEDURE leshchenko_food.add_product(
    p_restaurant_id uuid,
    p_product_category_id uuid,
    p_name varchar,
    p_price numeric,
    p_rating numeric,
    p_status leshchenko_food.product_status,
    p_description text,
    p_photo_url text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- BR-5.1: Проверка существования ресторана
    IF NOT EXISTS (SELECT 1 FROM leshchenko_food.restaurant WHERE restaurant_id = p_restaurant_id) THEN
        RAISE EXCEPTION 'BR-5.1: ресторан не найден' USING ERRCODE = '23503';
    END IF;

    -- BR-5.1: Проверка существования категории
    IF NOT EXISTS (SELECT 1 FROM leshchenko_food.product_category WHERE product_category_id = p_product_category_id) THEN
        RAISE EXCEPTION 'BR-5.1: категория блюда не найдена' USING ERRCODE = '23503';
    END IF;

    -- BR-5.3: Цена блюда неотрицательна
    IF p_price < 0 THEN
        RAISE EXCEPTION 'BR-5.3: цена блюда не может быть отрицательной' USING ERRCODE = '23514';
    END IF;

    -- Вставка блюда с серверным UUID
    INSERT INTO leshchenko_food.product (
        product_id,
        product_name,
        product_category_id,
        price,
        restaurant_id,
        photo_url,
        rating,
        status,
        description
    ) VALUES (
        exts.uuid_generate_v4(),
        p_name,
        p_product_category_id,
        p_price,
        p_restaurant_id,
        p_photo_url,
        p_rating,
        p_status,
        p_description
    );
END;
$$;

-- 2. FOOD-106: Статистика по ресторанам (get_statistic) (BR-11.8)

CREATE OR REPLACE FUNCTION leshchenko_food.get_statistic()
RETURNS TABLE (
    restaurant_name varchar,
    best_product_name varchar,
    total_amount numeric,
    avg_amount numeric,
    best_user varchar
)
LANGUAGE sql
STABLE
AS $$
    WITH delivered AS MATERIALIZED (
        SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
        FROM leshchenko_food."order" o
        WHERE o.status = 'доставлен'
    ),
    r_totals AS (
        SELECT d.restaurant_id,
               round(sum(d.total_amount), 2) AS total_amount,
               round(avg(d.total_amount), 2) AS avg_amount
        FROM delivered d
        GROUP BY d.restaurant_id
    ),
    best_prod AS (
        SELECT DISTINCT ON (d.restaurant_id)
               d.restaurant_id,
               p.product_name AS best_product_name
        FROM delivered d
        JOIN leshchenko_food.order_structure os ON os.order_id = d.order_id
        JOIN leshchenko_food.product p ON p.product_id = os.product_id
        GROUP BY d.restaurant_id, p.product_id, p.product_name
        ORDER BY d.restaurant_id, sum(os.quantity) DESC, random()
    ),
    best_client AS (
        SELECT DISTINCT ON (d.restaurant_id)
               d.restaurant_id,
               c.login AS best_user
        FROM delivered d
        JOIN leshchenko_food.client c ON c.client_id = d.client_id
        GROUP BY d.restaurant_id, c.client_id, c.login
        ORDER BY d.restaurant_id, count(d.order_id) DESC, random()
    )
    SELECT r.restaurant_name,
           bp.best_product_name,
           coalesce(rt.total_amount, 0.00)::numeric AS total_amount,
           rt.avg_amount::numeric AS avg_amount,
           bc.best_user
    FROM leshchenko_food.restaurant r
    LEFT JOIN r_totals rt ON rt.restaurant_id = r.restaurant_id
    LEFT JOIN best_prod bp ON bp.restaurant_id = r.restaurant_id
    LEFT JOIN best_client bc ON bc.restaurant_id = r.restaurant_id;
$$;

-- 3. FOOD-107: Расчет зарплаты курьеров (courier_salary) (BR-10.2, BR-10.6)

CREATE OR REPLACE PROCEDURE leshchenko_food.courier_salary()
LANGUAGE plpgsql
AS $$
DECLARE
    v_year int := extract(year from current_date)::int;
    v_month int := extract(month from current_date)::int;
    v_start_ts timestamp := date_trunc('month', current_date);
    v_end_ts timestamp := (date_trunc('month', current_date) + interval '1 month');
    r RECORD;
    v_count int;
    v_comm numeric;
    v_coeff_used numeric;
    v_amount numeric;
    v_next_coeff numeric;
BEGIN
    FOR r IN SELECT c.courier_id, c.status, c.coefficient FROM leshchenko_food.courier c LOOP
        -- Считаем только доставленные заказы курьера за текущий месяц (по order_timestamp)
        SELECT count(*), coalesce(sum(o.commission), 0.00)
        INTO v_count, v_comm
        FROM leshchenko_food."order" o
        WHERE o.courier_id = r.courier_id
          AND o.status = 'доставлен'
          AND o.order_timestamp >= v_start_ts
          AND o.order_timestamp < v_end_ts;

        -- Если за этот месяц курьеру уже рассчитывалась зарплата, сохраняем примененный коэффициент
        SELECT coefficient_used INTO v_coeff_used
        FROM leshchenko_food.courier_pay
        WHERE year = v_year AND month = v_month AND courier_id = r.courier_id;

        IF v_coeff_used IS NULL THEN
            v_coeff_used := r.coefficient;
        END IF;

        v_amount := round(v_coeff_used * v_comm, 2);

        -- Внесение / обновление записи в courier_pay
        INSERT INTO leshchenko_food.courier_pay (year, month, courier_id, amount, coefficient_used)
        VALUES (v_year, v_month, r.courier_id, v_amount, v_coeff_used)
        ON CONFLICT (year, month, courier_id)
        DO UPDATE SET amount = EXCLUDED.amount;

        -- Определение нового коэффициента на следующий месяц (BR-10.2)
        IF v_count <= 150 THEN
            v_next_coeff := 0.1;
        ELSIF v_count <= 250 THEN
            v_next_coeff := 0.2;
        ELSIF v_count <= 500 THEN
            v_next_coeff := 0.3;
        ELSE
            v_next_coeff := 0.5;
        END IF;

        -- Для работающих курьеров обновляем коэффициент; для уволенных не обновляем (BR-10.6)
        IF r.status != 'уволен' THEN
            UPDATE leshchenko_food.courier
            SET coefficient = v_next_coeff
            WHERE courier_id = r.courier_id;
        END IF;
    END LOOP;
END;
$$;

-- 4. FOOD-108: Отчет «сколько денег» (how_much_money) (BR-11.9)

CREATE OR REPLACE VIEW leshchenko_food.how_much_money AS
WITH RECURSIVE
bounds AS (
    SELECT min(date_trunc('month', order_timestamp)) AS min_month,
           max(date_trunc('month', order_timestamp)) AS max_month
    FROM leshchenko_food."order"
    WHERE status = 'доставлен'
),
months AS (
    SELECT min_month AS m FROM bounds WHERE min_month IS NOT NULL
    UNION ALL
    SELECT (m + interval '1 month')::timestamp
    FROM months, bounds
    WHERE m < bounds.max_month
),
ord_agg AS (
    SELECT date_trunc('month', order_timestamp) AS m,
           round(sum(order_amount), 2) AS sum_no_comm,
           round(sum(total_amount), 2) AS sum_with_comm
    FROM leshchenko_food."order"
    WHERE status = 'доставлен'
    GROUP BY date_trunc('month', order_timestamp)
),
pay_agg AS (
    SELECT make_date(cp.year, cp.month, 1)::timestamp AS m,
           round(sum(cp.amount), 2) AS courier_pay
    FROM leshchenko_food.courier_pay cp
    GROUP BY cp.year, cp.month
),
base AS (
    SELECT to_char(m.m, 'YYYY-MM') AS year_month,
           coalesce(oa.sum_no_comm, 0.00)::numeric AS sum_no_commission,
           coalesce(oa.sum_with_comm, 0.00)::numeric AS sum_with_commission,
           coalesce(oa.sum_with_comm - oa.sum_no_comm, 0.00)::numeric AS commission,
           coalesce(pa.courier_pay, 0.00)::numeric AS courier_pay,
           m.m AS sort_key
    FROM months m
    LEFT JOIN ord_agg oa ON oa.m = m.m
    LEFT JOIN pay_agg pa ON pa.m = m.m
)
SELECT year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       lag(commission) OVER (ORDER BY sort_key) AS prev_commission,
       commission - lag(commission) OVER (ORDER BY sort_key) AS commission_diff,
       courier_pay,
       commission - courier_pay AS net_profit
FROM base
ORDER BY sort_key;
