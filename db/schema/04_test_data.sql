-- db/schema/04_test_data.sql
-- Генератор и очистка тестовых данных (FOOD-102, FOOD-103)

-- Последовательность для уникальных номеров телефонов без коллизий при повторных запусках
CREATE SEQUENCE IF NOT EXISTS leshchenko_food.phone_seq START 1000000001;

-- 1. FOOD-102: Генератор тестовых данных (insert_test_data)

CREATE OR REPLACE PROCEDURE leshchenko_food.insert_test_data(value int)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Проверка входных данных
    v_n int := value;
    i int;
    j int;
    m_idx int;

    -- Массивы UUID текущей пачки
    v_client_ids uuid[];
    v_courier_ids uuid[];
    v_category_ids uuid[];
    v_restaurant_ids uuid[];
    v_restaurant_addr_ids uuid[];
    v_client_addr_ids uuid[];
    v_product_ids uuid[];
    v_order_ids uuid[];
    v_payment_ids uuid[];
    v_review_ids uuid[];

    -- Рабочие переменные для сущностей
    v_cid uuid;
    v_c_phone varchar(12);
    v_login varchar(100);

    v_crid uuid;
    v_cr_status leshchenko_food.courier_status;
    v_cr_hire date;
    v_cr_dismiss date;
    v_cr_coeff numeric(2,1);

    v_cat_id uuid;
    v_r_id uuid;
    v_r_addr_id uuid;

    v_p_id uuid;
    v_p_price numeric(14,2);

    v_o_id uuid;
    v_o_client_id uuid;
    v_o_addr_id uuid;
    v_o_courier_id uuid;
    v_o_restaurant_id uuid;
    v_o_status leshchenko_food.order_status;
    v_o_ts timestamp;
    v_del_ts timestamp;
    v_o_amount numeric(14,2);
    v_comm numeric(14,2);
    v_tot numeric(14,2);

    v_item_count int;
    v_prod_idx int;
    v_qty numeric(12,3);
    v_unit_p numeric(14,2);

    v_pay_id uuid;
    v_rev_id uuid;
    v_rev_type leshchenko_food.review_entity_type;
    v_rev_target uuid;

    -- Переменные для расчета зарплат за 6 месяцев
    v_cur_m timestamp;
    v_y int;
    v_m int;
    v_del_count int;
    v_comm_sum numeric(14,2);
    v_pay_amount numeric(14,2);
    v_cur_coeff numeric(2,1);
    v_next_coeff numeric(2,1);
BEGIN
    IF value IS NULL OR value < 0 THEN
        RAISE EXCEPTION 'value должен быть неотрицательным' USING ERRCODE = '22023';
    END IF;

    IF value = 0 THEN
        RETURN;
    END IF;

    -- Выделяем массивы UUID
    v_client_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n));
    v_courier_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n));
    v_category_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n));
    v_restaurant_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n));
    v_restaurant_addr_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n));
    v_client_addr_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n * 4));
    v_product_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n * 5));
    v_order_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n * 5));
    v_payment_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n * 5));
    v_review_ids := ARRAY(SELECT exts.uuid_generate_v4() FROM generate_series(1, v_n * 5));

    -- 1. Создание адресов: ровно value * 5
    -- value адресов под рестораны (BR-11.7)
    FOR i IN 1..v_n LOOP
        INSERT INTO leshchenko_food.address (address_id, street, house_number, apartment_office)
        VALUES (
            v_restaurant_addr_ids[i],
            'Ресторанная ул. ' || replace(v_restaurant_addr_ids[i]::text, '-', ''),
            i::text,
            NULL
        );
    END LOOP;

    -- value * 4 адресов под клиентов (BR-11.7)
    FOR i IN 1..(v_n * 4) LOOP
        INSERT INTO leshchenko_food.address (address_id, street, house_number, apartment_office)
        VALUES (
            v_client_addr_ids[i],
            'Клиентская ул. ' || replace(v_client_addr_ids[i]::text, '-', ''),
            ((i % 100) + 1)::text,
            'кв. ' || i::text
        );
    END LOOP;

    -- 2. Создание клиентов: ровно value (BR-2, BR-11.7)
    FOR i IN 1..v_n LOOP
        v_cid := v_client_ids[i];
        v_login := 'client_' || replace(v_cid::text, '-', '');
        v_c_phone := '+7' || nextval('leshchenko_food.phone_seq')::text;

        INSERT INTO leshchenko_food.client (client_id, login, password, phone_number)
        VALUES (
            v_cid,
            v_login,
            md5(random()::text),
            v_c_phone
        );

        -- Связь M:N client_address: каждому клиенту ровно 4 адреса из клиентского пула
        FOR j IN 1..4 LOOP
            INSERT INTO leshchenko_food.client_address (client_id, address_id)
            VALUES (v_cid, v_client_addr_ids[(i - 1) * 4 + j]);
        END LOOP;
    END LOOP;

    -- 3. Создание категорий: ровно value (BR-5.7, BR-11.7)
    FOR i IN 1..v_n LOOP
        INSERT INTO leshchenko_food.product_category (product_category_id, product_category_name)
        VALUES (
            v_category_ids[i],
            'Категория ' || substring(replace(v_category_ids[i]::text, '-', ''), 1, 8)
        );
    END LOOP;

    -- 4. Создание курьеров: ровно value (BR-6, BR-11.7)
    FOR i IN 1..v_n LOOP
        v_crid := v_courier_ids[i];
        v_cr_hire := current_date - interval '180 days';
        
        -- Минимум первый курьер свободен (BR-6.6)
        IF i = 1 THEN
            v_cr_status := 'свободен';
            v_cr_dismiss := NULL;
        ELSE
            -- Часть курьеров уволена
            IF (i % 5) = 0 THEN
                v_cr_status := 'уволен';
                v_cr_dismiss := current_date;
            ELSE
                v_cr_status := 'свободен';
                v_cr_dismiss := NULL;
            END IF;
        END IF;

        INSERT INTO leshchenko_food.courier (courier_id, FIO, phone_number, status, hire_date, dismissal_date, coefficient)
        VALUES (
            v_crid,
            'Курьер_' || substring(replace(v_crid::text, '-', ''), 1, 8),
            '+7' || nextval('leshchenko_food.phone_seq')::text,
            v_cr_status,
            v_cr_hire,
            v_cr_dismiss,
            0.1
        );
    END LOOP;

    -- 5. Создание ресторанов: ровно value (BR-4, BR-11.7)
    FOR i IN 1..v_n LOOP
        v_r_id := v_restaurant_ids[i];
        v_r_addr_id := v_restaurant_addr_ids[i];

        INSERT INTO leshchenko_food.restaurant (
            restaurant_id,
            restaurant_name,
            address_id,
            description,
            work_start,
            work_end,
            company_details,
            rating,
            status
        ) VALUES (
            v_r_id,
            'Ресторан ' || substring(replace(v_r_id::text, '-', ''), 1, 8),
            v_r_addr_id,
            'Описание ресторана ' || i,
            '09:00:00'::time,
            '23:00:00'::time,
            'ИНН 7701' || lpad(i::text, 6, '0') || ' ОГРН 10277000' || lpad(i::text, 5, '0'),
            NULL,
            'активен'
        );
    END LOOP;

    -- 6. Создание блюд: ровно value * 5 (по 5 на ресторан) (BR-5, BR-11.7)
    FOR i IN 1..v_n LOOP
        v_r_id := v_restaurant_ids[i];
        FOR j IN 1..5 LOOP
            v_p_id := v_product_ids[(i - 1) * 5 + j];
            -- Гарантируем цену блюда >= 1000, чтобы любой заказ удовлетворял минимальной сумме 1000 руб (BR-1.8)
            v_p_price := 1000.00 + ((j - 1) * 150.00);

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
                v_p_id,
                'Блюдо ' || i || '-' || j,
                v_category_ids[((i - 1) % v_n) + 1],
                v_p_price,
                v_r_id,
                'https://cdn.foodexpress.ru/img/' || replace(v_p_id::text, '-', '') || '.jpg',
                NULL,
                'доступно',
                'Описание блюда ' || i || '-' || j
            );
        END LOOP;
    END LOOP;

    -- 7. Создание заказов (value * 5), позиций, оплат и отзывов
    -- Ровно 5 заказов на ресторан (BR-11.7)
    FOR i IN 1..v_n LOOP
        v_r_id := v_restaurant_ids[i];
        v_o_client_id := v_client_ids[((i - 1) % v_n) + 1];

        FOR j IN 1..5 LOOP
            v_o_id := v_order_ids[(i - 1) * 5 + j];
            -- Адрес доставки — один из 4 адресов этого клиента (BR-7.4)
            v_o_addr_id := v_client_addr_ids[(((i - 1) % v_n)) * 4 + ((j - 1) % 4 + 1)];
            v_o_courier_id := v_courier_ids[((i + j - 2) % v_n) + 1];

            -- Статусы заказов: j = 1 всегда 'доставлен'
            IF j = 1 THEN
                v_o_status := 'доставлен';
            ELSIF j = 2 THEN
                v_o_status := 'создан';
            ELSIF j = 3 THEN
                v_o_status := 'готовится';
            ELSIF j = 4 THEN
                v_o_status := 'в_доставке';
            ELSE
                v_o_status := 'отменён';
            END IF;

            -- Распределение по 6 месяцам
            m_idx := ((i - 1) * 5 + (j - 1)) % 6; -- 0..5 (0 = 5 мес назад, 5 = текущий месяц)
            v_o_ts := (date_trunc('month', current_date - ((5 - m_idx) || ' months')::interval)
                       + interval '10 days' + ((j * 3) || ' hours')::interval);
            IF v_o_ts > localtimestamp THEN
                v_o_ts := localtimestamp - interval '2 hours';
            END IF;

            IF v_o_status = 'доставлен' THEN
                v_del_ts := v_o_ts + interval '40 minutes';
            ELSE
                v_del_ts := NULL;
            END IF;

            -- Позиции заказа: 1..j блюд из этого же ресторана (BR-7.3, BR-7.14, BR-7.16)
            v_item_count := j;
            v_o_amount := 0.00;
            FOR v_prod_idx IN 1..v_item_count LOOP
                v_p_id := v_product_ids[(i - 1) * 5 + v_prod_idx];
                v_unit_p := 1000.00 + ((v_prod_idx - 1) * 150.00);
                v_qty := 1.000;
                v_o_amount := v_o_amount + round(v_qty * v_unit_p, 2);
            END LOOP;

            v_comm := round(v_o_amount * 0.10, 2);
            v_tot := v_o_amount + v_comm;

            -- Вставка заказа (BR-7)
            INSERT INTO leshchenko_food."order" (
                order_id,
                courier_id,
                client_id,
                address_id,
                restaurant_id,
                order_timestamp,
                delivery_timestamp,
                order_amount,
                commission,
                total_amount,
                status,
                pay_status,
                description
            ) VALUES (
                v_o_id,
                v_o_courier_id,
                v_o_client_id,
                v_o_addr_id,
                v_r_id,
                v_o_ts,
                v_del_ts,
                v_o_amount,
                v_comm,
                v_tot,
                v_o_status,
                'оплачен',
                'Заказ ' || i || '-' || j
            );

            -- Вставка позиций в order_structure
            FOR v_prod_idx IN 1..v_item_count LOOP
                v_p_id := v_product_ids[(i - 1) * 5 + v_prod_idx];
                v_unit_p := 1000.00 + ((v_prod_idx - 1) * 150.00);
                INSERT INTO leshchenko_food.order_structure (order_id, product_id, quantity, unit_price)
                VALUES (v_o_id, v_p_id, 1.000, v_unit_p);
            END LOOP;

            -- 8. Оплата: ровно одна успешная оплата на заказ (BR-8.1, BR-8.4)
            v_pay_id := v_payment_ids[(i - 1) * 5 + j];
            INSERT INTO leshchenko_food.payment (
                payment_id,
                order_id,
                payment_type,
                amount,
                transaction_id,
                transaction_timestamp,
                status
            ) VALUES (
                v_pay_id,
                v_o_id,
                'карта',
                v_tot,
                exts.uuid_generate_v4(),
                v_o_ts + interval '5 minutes',
                'успех'
            );

            -- 9. Отзыв: ровно один отзыв на заказ (BR-9)
            v_rev_id := v_review_ids[(i - 1) * 5 + j];
            IF j = 1 THEN
                v_rev_type := 'блюдо';
                v_rev_target := v_product_ids[(i - 1) * 5 + 1];
            ELSIF j = 2 THEN
                v_rev_type := 'ресторан';
                v_rev_target := v_r_id;
            ELSIF j = 3 THEN
                v_rev_type := 'заказ';
                v_rev_target := v_o_id;
            ELSIF j = 4 THEN
                v_rev_type := 'блюдо';
                v_rev_target := v_product_ids[(i - 1) * 5 + 2];
            ELSE
                v_rev_type := 'ресторан';
                v_rev_target := v_r_id;
            END IF;

            INSERT INTO leshchenko_food.review (
                review_id,
                client_id,
                order_id,
                review_timestamp,
                entity_id,
                entity_type,
                description,
                photo_url,
                rating
            ) VALUES (
                v_rev_id,
                v_o_client_id,
                v_o_id,
                coalesce(v_del_ts, v_o_ts) + interval '10 minutes',
                v_rev_target,
                v_rev_type,
                'Отзыв к заказу ' || i || '-' || j,
                NULL,
                ((j % 5) + 1)::numeric(2,1)
            );
        END LOOP;
    END LOOP;

    -- 10. Заполнение courier_pay за 6 месяцев напрямую (FOOD-102, BR-10.2, BR-10.7)
    FOR i IN 1..v_n LOOP
        v_crid := v_courier_ids[i];
        v_cur_coeff := 0.1;

        FOR m_idx IN 0..5 LOOP
            v_cur_m := date_trunc('month', current_date - ((5 - m_idx) || ' months')::interval);
            v_y := extract(year from v_cur_m)::int;
            v_m := extract(month from v_cur_m)::int;

            -- Доставки этого курьера за этот месяц
            SELECT count(*), coalesce(sum(commission), 0.00)
            INTO v_del_count, v_comm_sum
            FROM leshchenko_food."order"
            WHERE courier_id = v_crid
              AND status = 'доставлен'
              AND date_trunc('month', order_timestamp) = v_cur_m;

            v_pay_amount := round(v_cur_coeff * v_comm_sum, 2);

            INSERT INTO leshchenko_food.courier_pay (year, month, courier_id, amount, coefficient_used)
            VALUES (v_y, v_m, v_crid, v_pay_amount, v_cur_coeff);

            -- Расчет следующего коэффициента
            IF v_del_count <= 150 THEN
                v_next_coeff := 0.1;
            ELSIF v_del_count <= 250 THEN
                v_next_coeff := 0.2;
            ELSIF v_del_count <= 500 THEN
                v_next_coeff := 0.3;
            ELSE
                v_next_coeff := 0.5;
            END IF;

            -- Если курьер уволен в текущем месяце, коэффициент не обновляется
            IF i = 1 OR (i % 5) != 0 OR m_idx < 5 THEN
                v_cur_coeff := v_next_coeff;
            END IF;
        END LOOP;

        -- Обновляем courier.coefficient рассчитанным значением
        IF i = 1 OR (i % 5) != 0 THEN
            UPDATE leshchenko_food.courier
            SET coefficient = v_cur_coeff
            WHERE courier_id = v_crid;
        END IF;
    END LOOP;
END;
$$;

-- 2. FOOD-103: Удаление тестовых данных (erase_test_data)

CREATE OR REPLACE PROCEDURE leshchenko_food.erase_test_data()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE TABLE
        leshchenko_food.review,
        leshchenko_food.payment,
        leshchenko_food.order_structure,
        leshchenko_food."order",
        leshchenko_food.courier_pay,
        leshchenko_food.courier,
        leshchenko_food.client_address,
        leshchenko_food.product,
        leshchenko_food.product_category,
        leshchenko_food.restaurant,
        leshchenko_food.client,
        leshchenko_food.address;
END;
$$;
