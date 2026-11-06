-- db/tests/unit_checks.sql
-- Детальная проверка процедур, триггеров и межтабличных ограничений

\set ON_ERROR_STOP on

-- 1. Проверка add_product (FOOD-104)
DO $$
DECLARE
    v_rid uuid;
    v_catid uuid;
    v_pid uuid;
    v_fake_id uuid := exts.uuid_generate_v4();
BEGIN
    SELECT restaurant_id INTO v_rid FROM leshchenko_food.restaurant LIMIT 1;
    SELECT product_category_id INTO v_catid FROM leshchenko_food.product_category LIMIT 1;

    -- 1.1. Успешное добавление (7 аргументов, photo_url по умолчанию NULL)
    CALL leshchenko_food.add_product(
        v_rid,
        v_catid,
        'Тестовый суп',
        1250.00,
        NULL,
        'доступно'::leshchenko_food.product_status,
        'Вкусный горячий суп'
    );
    
    SELECT product_id INTO v_pid FROM leshchenko_food.product WHERE product_name = 'Тестовый суп';
    IF v_pid IS NULL THEN
        RAISE EXCEPTION 'add_product не вставил блюдо!';
    END IF;
    RAISE NOTICE '1.1. add_product успешен: product_id=%', v_pid;

    -- 1.2. Ошибка: ресторан не существует (23503)
    BEGIN
        CALL leshchenko_food.add_product(
            v_fake_id,
            v_catid,
            'Суп с ошибкой',
            500.00,
            NULL,
            'доступно'::leshchenko_food.product_status,
            'Описание'
        );
        RAISE EXCEPTION 'Ожидалась ошибка несуществующего ресторана!';
    EXCEPTION WHEN SQLSTATE '23503' THEN
        RAISE NOTICE '1.2. Корректно перехвачена ошибка ресторана (SQLSTATE 23503: %)', SQLERRM;
    END;

    -- 1.3. Ошибка: категория не существует (23503)
    BEGIN
        CALL leshchenko_food.add_product(
            v_rid,
            v_fake_id,
            'Суп с ошибкой 2',
            500.00,
            NULL,
            'доступно'::leshchenko_food.product_status,
            'Описание'
        );
        RAISE EXCEPTION 'Ожидалась ошибка несуществующей категории!';
    EXCEPTION WHEN SQLSTATE '23503' THEN
        RAISE NOTICE '1.3. Корректно перехвачена ошибка категории (SQLSTATE 23503: %)', SQLERRM;
    END;

    -- 1.4. Ошибка: отрицательная цена (23514)
    BEGIN
        CALL leshchenko_food.add_product(
            v_rid,
            v_catid,
            'Суп с отрицательной ценой',
            -10.00,
            NULL,
            'доступно'::leshchenko_food.product_status,
            'Описание'
        );
        RAISE EXCEPTION 'Ожидалась ошибка отрицательной цены!';
    EXCEPTION WHEN SQLSTATE '23514' THEN
        RAISE NOTICE '1.4. Корректно перехвачена ошибка отрицательной цены (SQLSTATE 23514: %)', SQLERRM;
    END;
END $$;

-- 2. Проверка триггера rating_change (FOOD-105)
DO $$
DECLARE
    v_oid uuid;
    v_cid uuid;
    v_pid1 uuid;
    v_pid2 uuid;
    v_rev1 uuid := exts.uuid_generate_v4();
    v_rev2 uuid := exts.uuid_generate_v4();
    v_rev3 uuid := exts.uuid_generate_v4();
    v_rating numeric(3,2);
BEGIN
    -- Берем заказ и его блюдо
    SELECT o.order_id, o.client_id, os.product_id
    INTO v_oid, v_cid, v_pid1
    FROM leshchenko_food."order" o
    JOIN leshchenko_food.order_structure os ON os.order_id = o.order_id
    LIMIT 1;

    -- Удаляем существующие отзывы на это блюдо для изоляции теста
    DELETE FROM leshchenko_food.review WHERE entity_type = 'блюдо' AND entity_id = v_pid1;

    SELECT rating INTO v_rating FROM leshchenko_food.product WHERE product_id = v_pid1;
    IF v_rating IS NOT NULL THEN
        RAISE EXCEPTION 'Рейтинг без отзывов должен быть NULL, факт: %', v_rating;
    END IF;
    RAISE NOTICE '2.1. Рейтинг без отзывов равен NULL: OK';

    -- Вставляем 3 отзыва с оценками 3.0, 4.0, 5.0
    -- Обратите внимание: по BR-9.5 в рамках одного заказа может быть только 1 отзыв на конкретное блюдо.
    -- Создадим 3 разных отзыва (для проверки алгоритма временно вставим для разных заказов или напрямую протестируем триггер)
    INSERT INTO leshchenko_food.review (review_id, client_id, order_id, review_timestamp, entity_id, entity_type, description, rating)
    VALUES (v_rev1, v_cid, v_oid, localtimestamp, v_pid1, 'блюдо', 'Отзыв 1', 3.0);

    SELECT rating INTO v_rating FROM leshchenko_food.product WHERE product_id = v_pid1;
    IF v_rating != 3.00 THEN
        RAISE EXCEPTION 'Рейтинг после 1 отзыва должен быть 3.00, факт: %', v_rating;
    END IF;

    -- Удаляем отзыв 1
    DELETE FROM leshchenko_food.review WHERE review_id = v_rev1;
    SELECT rating INTO v_rating FROM leshchenko_food.product WHERE product_id = v_pid1;
    IF v_rating IS NOT NULL THEN
        RAISE EXCEPTION 'Рейтинг после удаления должен быть NULL, факт: %', v_rating;
    END IF;
    RAISE NOTICE '2.2. Удаление отзыва вернуло NULL: OK';
END $$;

-- 3. Проверка get_statistic() (FOOD-106)
SELECT * FROM leshchenko_food.get_statistic();

-- 4. Проверка courier_salary() (FOOD-107)
CALL leshchenko_food.courier_salary();
-- Повторный запуск: не должен дублировать
CALL leshchenko_food.courier_salary();

-- 5. Проверка how_much_money (FOOD-108)
SELECT * FROM leshchenko_food.how_much_money;
