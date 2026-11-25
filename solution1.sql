-- Q1 (a) Tables
CREATE TABLE medicines (
  medicine_id SERIAL PRIMARY KEY,
  medicine_name TEXT NOT NULL,
  unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
  sale_id SERIAL PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity INT NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on DATE NOT NULL
);

CREATE TABLE stock_audit (
  audit_id SERIAL PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty INT NOT NULL,
  new_qty INT NOT NULL,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
  sales_date DATE PRIMARY KEY,
  total_qty INT NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines(medicine_name, unit_price, stock_qty) VALUES
  ('Paracetamol 500mg', 5.00, 50),
  ('Amoxicillin 500mg', 12.50, 30),
  ('ORS Sachet', 3.00, 8);

-- Q1 (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(10,2) LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
  IF p_medicine_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid medicine or quantity';
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id; END IF;
  RETURN v_price * p_quantity;
END; $$;

-- Q1 (d) Trigger: AFTER UPDATE on medicines
CREATE OR REPLACE FUNCTION trg_medicines_stock_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
    INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty);
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_medicines_stock_audit();

-- Q1 (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_stock INT; v_price NUMERIC(10,2);
BEGIN
  IF p_medicine_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 OR p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Invalid sale inputs';
  END IF;
  SELECT stock_qty, unit_price INTO v_stock, v_price
  FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id; END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: have %, requested %', v_stock, p_quantity;
  END IF;
  INSERT INTO sales(medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
  UPDATE medicines SET stock_qty = stock_qty - p_quantity
  WHERE medicine_id = p_medicine_id;
END; $$;

-- Q1 (e) View
CREATE OR REPLACE VIEW vw_sales_report AS
SELECT s.sale_id, m.medicine_name, s.quantity, s.unit_price,
  (s.quantity * s.unit_price) AS total_value, s.sold_on
FROM sales s
JOIN medicines m ON m.medicine_id = s.medicine_id;

-- Q1 (f) Index
CREATE INDEX IF NOT EXISTS idx_sales_sold_on ON sales(sold_on);
CREATE INDEX IF NOT EXISTS idx_sales_medicine_id ON sales(medicine_id);

-- Q1 (g) Job: refresh daily_sales
CREATE OR REPLACE PROCEDURE pr_refresh_daily_sales()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales(sales_date, total_qty, total_amount)
  SELECT sold_on, SUM(quantity), SUM(quantity * unit_price)
  FROM sales GROUP BY sold_on
  ON CONFLICT (sales_date) DO UPDATE
  SET total_qty = EXCLUDED.total_qty,
      total_amount = EXCLUDED.total_amount;
END; $$;

SELECT cron.schedule('daily-sales-refresh', '0 1 * * *', 'CALL pr_refresh_daily_sales();');