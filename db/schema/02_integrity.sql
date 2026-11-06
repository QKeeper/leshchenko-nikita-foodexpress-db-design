-- db/schema/02_integrity.sql
-- Межтабличные ограничения, триггеры целостности и пересчёта (FOOD-101, FOOD-105)

-- 1. Триггер синхронизации статуса оплаты заказа (order.pay_status) (BR-8.7)

CREATE OR REPLACE FUNCTION leshchenko_food.sync_order_pay_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_ids uuid[] := '{}';
    v_oid uuid;
    v_success int;
    v_pending int;
    v_total int;
    v_new_status leshchenko_food.order_pay_status;
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.order_id IS NOT NULL THEN
        v_order_ids := array_append(v_order_ids, NEW.order_id);
    END IF;
    IF (TG_OP = 'DELETE' OR TG_OP = 'UPDATE') AND OLD.order_id IS NOT NULL THEN
        IF NOT (OLD.order_id = ANY(v_order_ids)) THEN
            v_order_ids := array_append(v_order_ids, OLD.order_id);
        END IF;
    END IF;

    FOREACH v_oid IN ARRAY v_order_ids LOOP
        SELECT
            count(*) FILTER (WHERE status = 'успех'),
            count(*) FILTER (WHERE status = 'в_обработке'),
            count(*)
        INTO v_success, v_pending, v_total
        FROM leshchenko_food.payment
        WHERE order_id = v_oid;

        IF v_success > 0 THEN
            v_new_status := 'оплачен';
        ELSIF v_total = 0 OR v_pending > 0 THEN
            v_new_status := 'ожидает';
        ELSE
            v_new_status := 'ошибка';
        END IF;

        UPDATE leshchenko_food."order"
        SET pay_status = v_new_status
        WHERE order_id = v_oid AND pay_status != v_new_status;
    END LOOP;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_order_pay_status ON leshchenko_food.payment;
CREATE TRIGGER trg_sync_order_pay_status
AFTER INSERT OR UPDATE OR DELETE ON leshchenko_food.payment
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.sync_order_pay_status();

-- 2. Отложенный триггер проверки межтабличной целостности заказа (BR-7, BR-8, BR-9)

CREATE OR REPLACE FUNCTION leshchenko_food.check_order_integrity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_ids uuid[] := '{}';
    v_order_id uuid;
    v_order RECORD;
    v_item_count int;
    v_calculated_amount numeric(14,2);
    v_success_pay int;
    v_pending_pay int;
    v_total_pay int;
    v_expected_pay_status leshchenko_food.order_pay_status;
    v_review RECORD;
BEGIN
    IF TG_TABLE_NAME = 'order' THEN
        IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.order_id IS NOT NULL THEN
            v_order_ids := array_append(v_order_ids, NEW.order_id);
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.order_id IS NOT NULL AND OLD.order_id != NEW.order_id THEN
            v_order_ids := array_append(v_order_ids, OLD.order_id);
        END IF;

    ELSIF TG_TABLE_NAME = 'order_structure' THEN
        IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.order_id IS NOT NULL THEN
            v_order_ids := array_append(v_order_ids, NEW.order_id);
        END IF;
        IF TG_OP IN ('DELETE', 'UPDATE') AND OLD.order_id IS NOT NULL THEN
            IF NOT (OLD.order_id = ANY(v_order_ids)) THEN
                v_order_ids := array_append(v_order_ids, OLD.order_id);
            END IF;
        END IF;

    ELSIF TG_TABLE_NAME = 'payment' THEN
        IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.order_id IS NOT NULL THEN
            v_order_ids := array_append(v_order_ids, NEW.order_id);
        END IF;
        IF TG_OP IN ('DELETE', 'UPDATE') AND OLD.order_id IS NOT NULL THEN
            IF NOT (OLD.order_id = ANY(v_order_ids)) THEN
                v_order_ids := array_append(v_order_ids, OLD.order_id);
            END IF;
        END IF;

    ELSIF TG_TABLE_NAME = 'review' THEN
        IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.order_id IS NOT NULL THEN
            v_order_ids := array_append(v_order_ids, NEW.order_id);
        END IF;
        IF TG_OP IN ('DELETE', 'UPDATE') AND OLD.order_id IS NOT NULL THEN
            IF NOT (OLD.order_id = ANY(v_order_ids)) THEN
                v_order_ids := array_append(v_order_ids, OLD.order_id);
            END IF;
        END IF;

    ELSIF TG_TABLE_NAME = 'product' THEN
        IF TG_OP = 'UPDATE' AND OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id THEN
            SELECT coalesce(array_agg(DISTINCT os.order_id), '{}')
            INTO v_order_ids
            FROM leshchenko_food.order_structure os
            WHERE os.product_id = NEW.product_id;
        END IF;
    END IF;

    FOREACH v_order_id IN ARRAY v_order_ids LOOP
        SELECT * INTO v_order FROM leshchenko_food."order" WHERE order_id = v_order_id;
        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        -- BR-7.14: Заказ содержит одну или несколько позиций
        SELECT count(*), coalesce(sum(round(quantity * unit_price, 2)), 0.00)
        INTO v_item_count, v_calculated_amount
        FROM leshchenko_food.order_structure
        WHERE order_id = v_order_id;

        IF v_item_count = 0 THEN
            RAISE EXCEPTION 'BR-7.14: Заказ % должен содержать хотя бы одну позицию', v_order_id
                USING ERRCODE = '23514';
        END IF;

        -- BR-7.3: Все блюда в заказе из ресторана заказа
        IF EXISTS (
            SELECT 1
            FROM leshchenko_food.order_structure os
            JOIN leshchenko_food.product p ON p.product_id = os.product_id
            WHERE os.order_id = v_order_id
              AND p.restaurant_id != v_order.restaurant_id
        ) THEN
            RAISE EXCEPTION 'BR-7.3: Все блюда в заказе % должны принадлежать ресторану заказа', v_order_id
                USING ERRCODE = '23514';
        END IF;

        -- BR-7.10: order_amount совпадает со стоимостью позиций
        IF v_order.order_amount != v_calculated_amount THEN
            RAISE EXCEPTION 'BR-7.10: Сумма заказа % (%) не совпадает с суммой позиций (%)',
                v_order_id, v_order.order_amount, v_calculated_amount
                USING ERRCODE = '23514';
        END IF;

        -- BR-8.4: Сумма каждой попытки оплаты равна общей сумме заказа
        IF EXISTS (
            SELECT 1
            FROM leshchenko_food.payment py
            WHERE py.order_id = v_order_id
              AND py.amount != v_order.total_amount
        ) THEN
            RAISE EXCEPTION 'BR-8.4: Сумма попытки оплаты должна быть равна общей сумме заказа %', v_order_id
                USING ERRCODE = '23514';
        END IF;

        -- BR-8.7: Статус оплаты заказа соответствует попыткам
        SELECT
            count(*) FILTER (WHERE status = 'успех'),
            count(*) FILTER (WHERE status = 'в_обработке'),
            count(*)
        INTO v_success_pay, v_pending_pay, v_total_pay
        FROM leshchenko_food.payment
        WHERE order_id = v_order_id;

        IF v_success_pay > 0 THEN
            v_expected_pay_status := 'оплачен';
        ELSIF v_total_pay = 0 OR v_pending_pay > 0 THEN
            v_expected_pay_status := 'ожидает';
        ELSE
            v_expected_pay_status := 'ошибка';
        END IF;

        IF v_order.pay_status != v_expected_pay_status THEN
            RAISE EXCEPTION 'BR-8.7: Статус оплаты заказа % (%) не соответствует попыткам оплаты (%)',
                v_order_id, v_order.pay_status, v_expected_pay_status
                USING ERRCODE = '23514';
        END IF;

        -- BR-8.1: Доставленный заказ должен иметь ровно одну успешную оплату
        IF v_order.status = 'доставлен' THEN
            IF v_order.pay_status != 'оплачен' OR v_success_pay != 1 THEN
                RAISE EXCEPTION 'BR-8.1: Доставленный заказ % должен иметь ровно одну успешную оплату', v_order_id
                    USING ERRCODE = '23514';
            END IF;
        END IF;

        -- BR-9.2: Валидность объектов отзывов, привязанных к заказу
        FOR v_review IN
            SELECT review_id, entity_type, entity_id
            FROM leshchenko_food.review
            WHERE order_id = v_order_id
        LOOP
            IF v_review.entity_type = 'заказ' THEN
                IF v_review.entity_id != v_order_id THEN
                    RAISE EXCEPTION 'BR-9.2: Отзыв % на заказ должен ссылаться на сам заказ %',
                        v_review.review_id, v_order_id USING ERRCODE = '23514';
                END IF;
            ELSIF v_review.entity_type = 'ресторан' THEN
                IF v_review.entity_id != v_order.restaurant_id THEN
                    RAISE EXCEPTION 'BR-9.2: Отзыв % на ресторан должен ссылаться на ресторан заказа %',
                        v_review.review_id, v_order_id USING ERRCODE = '23514';
                END IF;
            ELSIF v_review.entity_type = 'блюдо' THEN
                IF NOT EXISTS (
                    SELECT 1 FROM leshchenko_food.order_structure os
                    WHERE os.order_id = v_order_id AND os.product_id = v_review.entity_id
                ) THEN
                    RAISE EXCEPTION 'BR-9.2: Отзыв % на блюдо должен ссылаться на блюдо из состава заказа %',
                        v_review.review_id, v_order_id USING ERRCODE = '23514';
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    RETURN NULL;
END;
$$;

-- Отложенные триггеры на всех таблицах, влияющих на целостность заказа
DROP TRIGGER IF EXISTS trg_check_order_integrity_order ON leshchenko_food."order";
CREATE CONSTRAINT TRIGGER trg_check_order_integrity_order
AFTER INSERT OR UPDATE ON leshchenko_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.check_order_integrity();

DROP TRIGGER IF EXISTS trg_check_order_integrity_structure ON leshchenko_food.order_structure;
CREATE CONSTRAINT TRIGGER trg_check_order_integrity_structure
AFTER INSERT OR UPDATE OR DELETE ON leshchenko_food.order_structure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.check_order_integrity();

DROP TRIGGER IF EXISTS trg_check_order_integrity_payment ON leshchenko_food.payment;
CREATE CONSTRAINT TRIGGER trg_check_order_integrity_payment
AFTER INSERT OR UPDATE OR DELETE ON leshchenko_food.payment
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.check_order_integrity();

DROP TRIGGER IF EXISTS trg_check_order_integrity_review ON leshchenko_food.review;
CREATE CONSTRAINT TRIGGER trg_check_order_integrity_review
AFTER INSERT OR UPDATE OR DELETE ON leshchenko_food.review
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.check_order_integrity();

DROP TRIGGER IF EXISTS trg_check_order_integrity_product ON leshchenko_food.product;
CREATE CONSTRAINT TRIGGER trg_check_order_integrity_product
AFTER UPDATE OF restaurant_id ON leshchenko_food.product
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.check_order_integrity();

-- 3. FOOD-105: Триггер пересчёта рейтинга (rating_change) (BR-9.6, BR-9.7)

CREATE OR REPLACE FUNCTION leshchenko_food.rating_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_targets RECORD;
BEGIN
    FOR v_targets IN
        SELECT DISTINCT entity_type, entity_id
        FROM (
            SELECT NEW.entity_type AS entity_type, NEW.entity_id AS entity_id
            WHERE TG_OP IN ('INSERT', 'UPDATE') AND NEW.entity_id IS NOT NULL
            UNION
            SELECT OLD.entity_type AS entity_type, OLD.entity_id AS entity_id
            WHERE TG_OP IN ('DELETE', 'UPDATE') AND OLD.entity_id IS NOT NULL
        ) t
    LOOP
        IF v_targets.entity_type = 'блюдо' THEN
            UPDATE leshchenko_food.product
            SET rating = (
                SELECT round(avg(rating)::numeric, 2)
                FROM leshchenko_food.review
                WHERE entity_type = 'блюдо' AND entity_id = v_targets.entity_id
            )
            WHERE product_id = v_targets.entity_id;

        ELSIF v_targets.entity_type = 'ресторан' THEN
            UPDATE leshchenko_food.restaurant
            SET rating = (
                SELECT round(avg(rating)::numeric, 2)
                FROM leshchenko_food.review
                WHERE entity_type = 'ресторан' AND entity_id = v_targets.entity_id
            )
            WHERE restaurant_id = v_targets.entity_id;

        -- Для entity_type = 'заказ' рейтинг не пересчитывается (BR-9.6)
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_review_rating_change ON leshchenko_food.review;
CREATE TRIGGER trg_review_rating_change
AFTER INSERT OR UPDATE OR DELETE ON leshchenko_food.review
FOR EACH ROW
EXECUTE FUNCTION leshchenko_food.rating_change();
