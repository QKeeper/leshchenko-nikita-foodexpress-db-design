-- db/tests/acceptance.sql
-- Полный автоматизированный тестовый прогон FoodExpress (FOOD-101 .. FOOD-110)
-- Запускается под ролью inspector или postgres

\set ON_ERROR_STOP on

SELECT version() AS pg_version, current_user, current_database(), current_setting('server_encoding') AS enc, current_setting('TimeZone') AS tz;

-- B. FOOD-101: Структура схемы

-- B.1. Схема leshchenko_food существует
SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'leshchenko_food';

-- B.2. Расширение uuid-ossp в схеме exts
SELECT extname, extnamespace::regnamespace AS schema FROM pg_extension WHERE extname = 'uuid-ossp';

-- B.3. Все 12 таблиц присутствуют
SELECT table_name FROM information_schema.tables WHERE table_schema = 'leshchenko_food' ORDER BY table_name;

-- B.4. Все PK/FK id-колонки имеют тип uuid
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'leshchenko_food' AND column_name LIKE '%_id' AND data_type != 'uuid';

-- B.5. 8 перечислимых типов с ожидаемыми значениями
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'leshchenko_food'
GROUP BY t.typname
ORDER BY t.typname;

-- B.6. Внешние ключи (FK)
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f' AND connamespace = 'leshchenko_food'::regnamespace
ORDER BY tbl, conname;

-- C & D: Генератор данных, очистка и проверка бизнес-правил

-- C.1. Очистка перед тестированием
CALL leshchenko_food.erase_test_data();

-- Проверка пустоты всех 12 таблиц
SELECT 'address' AS tbl, count(*) FROM leshchenko_food.address
UNION ALL SELECT 'client', count(*) FROM leshchenko_food.client
UNION ALL SELECT 'client_address', count(*) FROM leshchenko_food.client_address
UNION ALL SELECT 'courier', count(*) FROM leshchenko_food.courier
UNION ALL SELECT 'courier_pay', count(*) FROM leshchenko_food.courier_pay
UNION ALL SELECT 'order', count(*) FROM leshchenko_food."order"
UNION ALL SELECT 'order_structure', count(*) FROM leshchenko_food.order_structure
UNION ALL SELECT 'payment', count(*) FROM leshchenko_food.payment
UNION ALL SELECT 'product', count(*) FROM leshchenko_food.product
UNION ALL SELECT 'product_category', count(*) FROM leshchenko_food.product_category
UNION ALL SELECT 'restaurant', count(*) FROM leshchenko_food.restaurant
UNION ALL SELECT 'review', count(*) FROM leshchenko_food.review
ORDER BY tbl;

-- C.2. Генерация тестового набора n = 10
CALL leshchenko_food.insert_test_data(10);

-- C.3. Распределение строк по BR-11.7
SELECT 'client' AS tbl, count(*) FROM leshchenko_food.client
UNION ALL SELECT 'courier', count(*) FROM leshchenko_food.courier
UNION ALL SELECT 'product_category', count(*) FROM leshchenko_food.product_category
UNION ALL SELECT 'restaurant', count(*) FROM leshchenko_food.restaurant
UNION ALL SELECT 'address', count(*) FROM leshchenko_food.address
UNION ALL SELECT 'client_address', count(*) FROM leshchenko_food.client_address
UNION ALL SELECT 'product', count(*) FROM leshchenko_food.product
UNION ALL SELECT 'order', count(*) FROM leshchenko_food."order"
UNION ALL SELECT 'order_structure', count(*) FROM leshchenko_food.order_structure
UNION ALL SELECT 'payment', count(*) FROM leshchenko_food.payment
UNION ALL SELECT 'review', count(*) FROM leshchenko_food.review
UNION ALL SELECT 'courier_pay', count(*) FROM leshchenko_food.courier_pay
ORDER BY tbl;

-- C.4. Адреса ресторанов (10) vs клиентов (40) (BR-11.7)
SELECT 'restaurant addresses' AS cat, count(*) FROM leshchenko_food.restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'client addresses', count(DISTINCT address_id) FROM leshchenko_food.client_address
UNION ALL
SELECT 'total addresses', count(*) FROM leshchenko_food.address;

-- C.5. Нет пустых строк в обязательных текстовых полях
SELECT count(*) AS empty_strings_found FROM (
    SELECT 1 FROM leshchenko_food.client WHERE length(btrim(login)) = 0 OR length(btrim(password)) = 0 OR length(btrim(phone_number)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.address WHERE length(btrim(street)) = 0 OR length(btrim(house_number)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.courier WHERE length(btrim(FIO)) = 0 OR length(btrim(phone_number)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.restaurant WHERE length(btrim(restaurant_name)) = 0 OR length(btrim(description)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.product WHERE length(btrim(product_name)) = 0 OR length(btrim(description)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food."order" WHERE length(btrim(description)) = 0
    UNION ALL SELECT 1 FROM leshchenko_food.payment WHERE transaction_id IS NULL
    UNION ALL SELECT 1 FROM leshchenko_food.review WHERE length(btrim(description)) = 0
) t;

-- C.6. Нет запрещенных NULL
SELECT count(*) AS invalid_nulls FROM leshchenko_food."order"
WHERE client_id IS NULL OR restaurant_id IS NULL OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;

-- C.7. Минимум один активный курьер (BR-6.6)
SELECT count(*) AS active_couriers FROM leshchenko_food.courier WHERE status != 'уволен';

-- C.8. courier_pay консистентен с BR-10.2
SELECT count(*) AS courier_pay_mismatches
FROM (
    SELECT cp.year, cp.month, cp.courier_id, cp.amount,
           round(coalesce((
               SELECT sum(o.commission)
               FROM leshchenko_food."order" o
               WHERE o.courier_id = cp.courier_id
                 AND o.status = 'доставлен'
                 AND extract(year from o.order_timestamp) = cp.year
                 AND extract(month from o.order_timestamp) = cp.month
           ), 0) * cp.coefficient_used, 2) AS expected_amount
    FROM leshchenko_food.courier_pay cp
) t
WHERE amount != expected_amount;

-- B.7. Пароли клиентов — корректный MD5
SELECT count(*) AS non_md5_passwords FROM leshchenko_food.client WHERE password !~ '^[0-9a-f]{32}$';

-- D.1. Все FK валидны (0 orphans)
SELECT 'order_structure -> order' AS fk, count(*) AS orphans
FROM leshchenko_food.order_structure os LEFT JOIN leshchenko_food."order" o ON os.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'order_structure -> product', count(*) FROM leshchenko_food.order_structure os LEFT JOIN leshchenko_food.product p ON os.product_id = p.product_id WHERE p.product_id IS NULL
UNION ALL SELECT 'payment -> order', count(*) FROM leshchenko_food.payment pmt LEFT JOIN leshchenko_food."order" o ON pmt.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'review -> order', count(*) FROM leshchenko_food.review r LEFT JOIN leshchenko_food."order" o ON r.order_id = o.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'courier_pay -> courier', count(*) FROM leshchenko_food.courier_pay cp LEFT JOIN leshchenko_food.courier c ON cp.courier_id = c.courier_id WHERE c.courier_id IS NULL
UNION ALL SELECT 'client_address -> client', count(*) FROM leshchenko_food.client_address ca LEFT JOIN leshchenko_food.client c ON ca.client_id = c.client_id WHERE c.client_id IS NULL
UNION ALL SELECT 'client_address -> address', count(*) FROM leshchenko_food.client_address ca LEFT JOIN leshchenko_food.address a ON ca.address_id = a.address_id WHERE a.address_id IS NULL;

-- D.2. Минимальная сумма заказа >= 1000 (BR-1.8)
SELECT count(*) AS orders_below_1000 FROM leshchenko_food."order" WHERE total_amount < 1000.00;

-- D.3. Комиссия = 10% (BR-1.4)
SELECT count(*) AS commission_mismatches FROM leshchenko_food."order" WHERE round(order_amount * 0.10, 2) != commission;

-- D.4. total_amount = order_amount + commission (BR-1.5)
SELECT count(*) AS total_mismatches FROM leshchenko_food."order" WHERE round(order_amount + commission, 2) != total_amount;

-- D.5. Дата окончания доставки не раньше создания (BR-7.13)
SELECT count(*) AS bad_delivery_dates FROM leshchenko_food."order" WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;

-- D.6. Адрес доставки принадлежит клиенту (BR-7.4)
SELECT count(*) AS foreign_addresses
FROM leshchenko_food."order" o
LEFT JOIN leshchenko_food.client_address ca ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;

-- D.7. Все блюда в заказе из ресторана заказа (BR-7.3)
SELECT count(DISTINCT os.order_id) AS foreign_dishes
FROM leshchenko_food.order_structure os
JOIN leshchenko_food."order" o ON os.order_id = o.order_id
JOIN leshchenko_food.product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;

-- D.8. Ровно одна успешная оплата на заказ (BR-8.1)
SELECT count(*) AS non_unique_successful_payments
FROM (
    SELECT order_id FROM leshchenko_food.payment WHERE status = 'успех' GROUP BY order_id HAVING count(*) != 1
) t;

-- D.9. Сумма оплаты = total_amount заказа (BR-8.4)
SELECT count(*) AS payment_amount_mismatches
FROM leshchenko_food.payment p
JOIN leshchenko_food."order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;

-- D.10. Нет дубликатов в client_address (BR-2.5)
SELECT count(*) AS duplicate_client_addresses FROM (
    SELECT client_id, address_id FROM leshchenko_food.client_address GROUP BY client_id, address_id HAVING count(*) > 1
) t;

-- D.11. Нет дубликатов в order_structure (BR-7.16)
SELECT count(*) AS duplicate_order_structures FROM (
    SELECT order_id, product_id FROM leshchenko_food.order_structure GROUP BY order_id, product_id HAVING count(*) > 1
) t;

-- D.12. График работы ресторана: work_end > work_start (BR-4.4)
SELECT count(*) AS bad_work_hours FROM leshchenko_food.restaurant WHERE work_end <= work_start;

-- D.13. Даты курьера: dismissal_date >= hire_date (BR-6.3)
SELECT count(*) AS bad_courier_dates FROM leshchenko_food.courier WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;

-- D.14. Рейтинг блюд/ресторанов соответствует отзывам (BR-9.6)
SELECT count(*) AS rating_mismatches
FROM leshchenko_food.product p
WHERE p.rating IS NOT NULL
  AND p.rating != (SELECT round(avg(r.rating)::numeric, 2) FROM leshchenko_food.review r WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id);

-- E. Функции и процедуры

-- E.1. add_product — успешный вызов
DO $$
DECLARE
    v_cnt_before int;
    v_cnt_after int;
    v_rid uuid;
    v_cid uuid;
BEGIN
    SELECT count(*) INTO v_cnt_before FROM leshchenko_food.product;
    SELECT restaurant_id INTO v_rid FROM leshchenko_food.restaurant LIMIT 1;
    SELECT product_category_id INTO v_cid FROM leshchenko_food.product_category LIMIT 1;

    CALL leshchenko_food.add_product(
        p_restaurant_id => v_rid,
        p_product_category_id => v_cid,
        p_name => 'Пицца Тестовая',
        p_price => 1200.00,
        p_rating => NULL,
        p_status => 'доступно'::leshchenko_food.product_status,
        p_description => 'Тестовая пицца из приемочных тестов'
    );

    SELECT count(*) INTO v_cnt_after FROM leshchenko_food.product;
    IF v_cnt_after != v_cnt_before + 1 THEN
        RAISE EXCEPTION 'add_product не увеличил число блюд!';
    END IF;
    RAISE NOTICE 'E.1. add_product успешно добавил блюдо (было %, стало %)', v_cnt_before, v_cnt_after;
END $$;

-- E.2. add_product — падает с понятной ошибкой при несуществующем ресторане (23503)
DO $$
DECLARE
    v_cid uuid;
BEGIN
    SELECT product_category_id INTO v_cid FROM leshchenko_food.product_category LIMIT 1;
    BEGIN
        CALL leshchenko_food.add_product(
            p_restaurant_id => '00000000-0000-0000-0000-000000000000'::uuid,
            p_product_category_id => v_cid,
            p_name => 'Пицца Невозможная',
            p_price => 1000.00,
            p_rating => NULL,
            p_status => 'доступно'::leshchenko_food.product_status,
            p_description => 'Описание'
        );
        RAISE EXCEPTION 'Ожидалась ошибка несуществующего ресторана!';
    EXCEPTION WHEN SQLSTATE '23503' THEN
        RAISE NOTICE 'E.2. add_product корректно выбросил 23503: %', SQLERRM;
    END;
END $$;

-- E.3 & E.4. rating_change пересчет рейтинга при вставке и удалении
DO $$
DECLARE
    v_oid uuid;
    v_cid uuid;
    v_pid uuid;
    v_revid uuid := exts.uuid_generate_v4();
    v_rating_after_insert numeric(3,2);
    v_rating_after_delete numeric(3,2);
BEGIN
    SELECT o.order_id, o.client_id, os.product_id
    INTO v_oid, v_cid, v_pid
    FROM leshchenko_food."order" o
    JOIN leshchenko_food.order_structure os ON os.order_id = o.order_id
    WHERE NOT EXISTS (SELECT 1 FROM leshchenko_food.review r WHERE r.entity_type = 'блюдо' AND r.entity_id = os.product_id)
    LIMIT 1;

    INSERT INTO leshchenko_food.review (
        review_id, client_id, order_id, review_timestamp, entity_id, entity_type, description, rating
    ) VALUES (
        v_revid, v_cid, v_oid, localtimestamp, v_pid, 'блюдо', 'Проверочный отзыв', 4.0
    );

    SELECT rating INTO v_rating_after_insert FROM leshchenko_food.product WHERE product_id = v_pid;
    IF v_rating_after_insert != 4.00 THEN
        RAISE EXCEPTION 'Рейтинг после вставки должен быть 4.00, факт: %', v_rating_after_insert;
    END IF;

    DELETE FROM leshchenko_food.review WHERE review_id = v_revid;
    SELECT rating INTO v_rating_after_delete FROM leshchenko_food.product WHERE product_id = v_pid;
    IF v_rating_after_delete IS NOT NULL THEN
        RAISE EXCEPTION 'Рейтинг после удаления должен быть NULL, факт: %', v_rating_after_delete;
    END IF;

    RAISE NOTICE 'E.3-E.4. rating_change успешно отработал (вставка 4.00 -> удаление NULL)';
END $$;

-- E.5. get_statistic()
SELECT * FROM leshchenko_food.get_statistic() LIMIT 10;

-- E.6 & E.7. courier_salary() и повторный вызов
CALL leshchenko_food.courier_salary();
SELECT count(*) AS pay_records_after_first_call
FROM leshchenko_food.courier_pay
WHERE year = extract(year from current_date) AND month = extract(month from current_date);

CALL leshchenko_food.courier_salary();
SELECT count(*) AS pay_records_after_second_call
FROM leshchenko_food.courier_pay
WHERE year = extract(year from current_date) AND month = extract(month from current_date);

-- F. Представление how_much_money

-- F.1. Колонки представления
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'leshchenko_food' AND table_name = 'how_much_money'
ORDER BY ordinal_position;

-- F.2 - F.4. Данные отчета
SELECT year_month, sum_no_commission, sum_with_commission, commission, prev_commission, commission_diff, courier_pay, net_profit
FROM leshchenko_food.how_much_money;

-- H. EXPLAIN ANALYZE для get_statistic
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM leshchenko_food.get_statistic();

-- I. Итоговая очистка и фиксация канонического набора n = 10 для бэкапа
CALL leshchenko_food.erase_test_data();
CALL leshchenko_food.insert_test_data(10);

-- Финальная сводка строк перед дампом
SELECT
    (SELECT count(*) FROM leshchenko_food.client) AS clients,
    (SELECT count(*) FROM leshchenko_food.courier) AS couriers,
    (SELECT count(*) FROM leshchenko_food.product_category) AS categories,
    (SELECT count(*) FROM leshchenko_food.restaurant) AS restaurants,
    (SELECT count(*) FROM leshchenko_food.address) AS addresses,
    (SELECT count(*) FROM leshchenko_food.client_address) AS client_addresses,
    (SELECT count(*) FROM leshchenko_food.product) AS products,
    (SELECT count(*) FROM leshchenko_food."order") AS orders,
    (SELECT count(*) FROM leshchenko_food.order_structure) AS order_structures,
    (SELECT count(*) FROM leshchenko_food.payment) AS payments,
    (SELECT count(*) FROM leshchenko_food.review) AS reviews,
    (SELECT count(*) FROM leshchenko_food.courier_pay) AS courier_pays;
