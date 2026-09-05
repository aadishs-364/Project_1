"""
Generates sql/02_seed_data.sql.

The customer and product lists below are hand written so the catalogue looks
like a real store. Orders, order items and payments are simulated with a fixed
random seed, so re-running this script always reproduces the same dataset and
the numbers quoted in docs/insights_report.md stay valid.

Patterns deliberately baked into the transactional data:
  * year on year growth plus a festive spike around Oct/Nov
  * a small set of products that carry most of the revenue (Pareto)
  * a long tail of one-time buyers next to a core of repeat customers
  * cancellations, returns, failed payment attempts and refunds

Usage:  python tools/generate_seed_data.py
"""

import random
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

SEED = 20260904
OUT = Path(__file__).resolve().parents[1] / "sql" / "02_seed_data.sql"

START = date(2024, 1, 1)
END = date(2026, 8, 31)

rng = random.Random(SEED)

CENT = Decimal("0.01")


def money(value):
    """Round to paise the way SQL ROUND() does.

    Python's built-in round() is banker's rounding (half to even) and works on
    binary floats, while SQL rounds half away from zero on exact decimals. On
    a dataset this size the two disagree on a handful of order lines, which is
    enough to break the header_vs_lines integrity check in 03. Doing the
    arithmetic in Decimal with ROUND_HALF_UP makes the generated totals match
    what the database computes, exactly.
    """
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)


# ----------------------------------------------------------------------
# Reference data
# ----------------------------------------------------------------------

# (name, category, price, cost_price, popularity_weight)
PRODUCTS = [
    ("Aurora 27in 4K Monitor",            "Electronics",            28999, 21500,  9),
    ("Aurora 24in FHD Monitor",           "Electronics",            13499,  9900, 14),
    ("Nimbus Wireless Earbuds Pro",       "Electronics",             6499,  3600, 38),
    ("Nimbus Wireless Earbuds Lite",      "Electronics",             2299,  1150, 45),
    ("Vertex Mechanical Keyboard",        "Electronics",             5899,  3400, 18),
    ("Vertex Wireless Mouse",             "Electronics",             1599,   780, 30),
    ("Helios 65W GaN Charger",            "Electronics",             2199,  1050, 26),
    ("Helios 20000mAh Power Bank",        "Electronics",             2799,  1500, 24),
    ("Zenith Smart Watch S3",             "Electronics",            11999,  7200, 16),
    ("Zenith Fitness Band 2",             "Electronics",             3299,  1700, 21),
    ("Orbit Bluetooth Speaker",           "Electronics",             4499,  2400, 17),
    ("Orbit Soundbar 120W",               "Electronics",             9999,  6300,  8),

    ("CopperLine Non-Stick Cookware Set", "Home & Kitchen",          4299,  2500, 15),
    ("CopperLine Pressure Cooker 5L",     "Home & Kitchen",          2899,  1650, 18),
    ("BrewCraft Coffee Maker",            "Home & Kitchen",          5499,  3200, 12),
    ("BrewCraft Electric Kettle 1.7L",    "Home & Kitchen",          1499,   720, 27),
    ("PureAir Room Purifier",             "Home & Kitchen",         14999,  9800,  6),
    ("Meadow Cotton Bedsheet Set",        "Home & Kitchen",          2199,  1100, 20),
    ("Meadow Microfibre Pillow (2 pack)", "Home & Kitchen",           999,   420, 25),
    ("StoreWell Vacuum Container Set",    "Home & Kitchen",          1299,   560, 19),

    ("Trailhead Running Shoes",           "Fashion",                 3999,  1900, 28),
    ("Trailhead Trekking Backpack 40L",   "Fashion",                 2799,  1300, 16),
    ("UrbanKnit Oversized Hoodie",        "Fashion",                 1899,   820, 24),
    ("UrbanKnit Cotton T-Shirt",          "Fashion",                  799,   290, 40),
    ("Denim Co. Slim Fit Jeans",          "Fashion",                 2499,  1150, 22),
    ("Larkspur Analog Watch",             "Fashion",                 4599,  2100, 11),
    ("Larkspur Leather Wallet",           "Fashion",                 1299,   520, 23),
    ("SunGuard Polarised Sunglasses",     "Fashion",                 1799,   700, 18),

    ("IronCore Adjustable Dumbbell 20kg", "Sports & Fitness",        6999,  4200, 13),
    ("IronCore Resistance Band Set",      "Sports & Fitness",         899,   330, 26),
    ("FlexMat Yoga Mat 6mm",              "Sports & Fitness",        1199,   470, 29),
    ("FlexMat Foam Roller",               "Sports & Fitness",         999,   400, 15),
    ("RallyPro Badminton Racket",         "Sports & Fitness",        2699,  1400, 14),
    ("HydroFlask Steel Bottle 1L",        "Sports & Fitness",        1099,   430, 32),

    ("Inkwell Hardbound Notebook",        "Books & Stationery",       449,   150, 34),
    ("Inkwell Gel Pen Pack (10)",         "Books & Stationery",       299,    90, 36),
    ("The Analyst's Handbook",            "Books & Stationery",       899,   380, 12),
    ("Practical SQL for Analysts",        "Books & Stationery",      1199,   500, 17),
    ("DeskMate Organiser Tray",           "Books & Stationery",       749,   300, 13),

    ("GlowLab Vitamin C Serum",           "Beauty & Personal Care",  1299,   450, 22),
    ("GlowLab Daily Sunscreen SPF50",     "Beauty & Personal Care",   799,   270, 31),
    ("SilkSmooth Hair Dryer",             "Beauty & Personal Care",  2499,  1250, 14),
    ("SilkSmooth Beard Trimmer",          "Beauty & Personal Care",  1899,   900, 20),
]

CITIES = [
    ("Bengaluru", "Karnataka"), ("Mumbai", "Maharashtra"), ("Pune", "Maharashtra"),
    ("Delhi", "Delhi"), ("Gurugram", "Haryana"), ("Noida", "Uttar Pradesh"),
    ("Hyderabad", "Telangana"), ("Chennai", "Tamil Nadu"), ("Coimbatore", "Tamil Nadu"),
    ("Kolkata", "West Bengal"), ("Ahmedabad", "Gujarat"), ("Surat", "Gujarat"),
    ("Jaipur", "Rajasthan"), ("Lucknow", "Uttar Pradesh"), ("Indore", "Madhya Pradesh"),
    ("Kochi", "Kerala"), ("Bhubaneswar", "Odisha"), ("Chandigarh", "Chandigarh"),
]

FIRST_NAMES = [
    "Aarav", "Aditi", "Ananya", "Arjun", "Bhavya", "Chirag", "Devika", "Dhruv",
    "Farhan", "Gaurav", "Harini", "Ishaan", "Ishita", "Jatin", "Kavya", "Kiran",
    "Lakshmi", "Manish", "Meera", "Naveen", "Neha", "Nikhil", "Pallavi", "Parth",
    "Pooja", "Rahul", "Rakesh", "Ramya", "Riya", "Rohan", "Sahil", "Sanjana",
    "Shreya", "Siddharth", "Sneha", "Tanvi", "Tarun", "Uday", "Varun", "Vidya",
    "Vikram", "Yash", "Zoya", "Ayesha", "Karthik", "Nandini", "Omkar", "Preeti",
    "Rachit", "Swati", "Tejas", "Aisha", "Anil", "Divya", "Girish", "Hemant",
    "Jyoti", "Kunal", "Madhu", "Nitin",
]

LAST_NAMES = [
    "Sharma", "Verma", "Iyer", "Nair", "Reddy", "Kulkarni", "Patel", "Shah",
    "Banerjee", "Chatterjee", "Rao", "Menon", "Joshi", "Desai", "Gupta", "Mehta",
    "Kapoor", "Chauhan", "Pillai", "Sethi", "Bhat", "Ghosh", "Naidu", "Saxena",
]

PAYMENT_METHODS = ["UPI", "UPI", "UPI", "CREDIT_CARD", "CREDIT_CARD",
                   "DEBIT_CARD", "NET_BANKING", "WALLET", "COD"]

CHANNELS = ["MOBILE_APP", "MOBILE_APP", "MOBILE_APP", "WEB", "WEB",
            "MARKETPLACE", "STORE"]


# ----------------------------------------------------------------------
# Builders
# ----------------------------------------------------------------------

def build_customers(n=120):
    rows, used_emails = [], set()
    for i in range(1, n + 1):
        first = FIRST_NAMES[(i - 1) % len(FIRST_NAMES)]
        last = rng.choice(LAST_NAMES)
        name = f"{first} {last}"

        base = f"{first}.{last}".lower()
        email = f"{base}@example.com"
        suffix = 1
        while email in used_emails:
            suffix += 1
            email = f"{base}{suffix}@example.com"
        used_emails.add(email)

        city, state = rng.choice(CITIES)
        phone = "9" + "".join(str(rng.randint(0, 9)) for _ in range(9))

        # Most customers joined before the order window opens; roughly a fifth
        # sign up later on, which is what makes cohort analysis interesting.
        if rng.random() < 0.78:
            signup = date(2023, 6, 1) + timedelta(days=rng.randint(0, 213))
        else:
            signup = START + timedelta(days=rng.randint(0, 800))

        rows.append((i, name, email, phone, city, state, signup))
    return rows


def build_products():
    rows = []
    for pid, (nm, cat, price, cost, _w) in enumerate(PRODUCTS, start=1):
        stock = rng.choice([0, 0, 5, 12, 18, 25, 40, 60, 85, 120, 150, 240])
        is_active = False if rng.random() < 0.07 else True
        rows.append((pid, nm, cat, price, cost, stock, is_active))
    return rows


def month_starts(start, end):
    out, y, m = [], start.year, start.month
    while date(y, m, 1) <= end:
        out.append(date(y, m, 1))
        m += 1
        if m == 13:
            y, m = y + 1, 1
    return out


def monthly_order_target(month_start, index):
    """Base volume + ~14% annual growth + festive seasonality."""
    base = 30 + index * 0.75
    season = {
        1: 0.92, 2: 0.80, 3: 0.95, 4: 1.00, 5: 1.05, 6: 0.98,
        7: 1.02, 8: 1.08, 9: 1.10, 10: 1.45, 11: 1.35, 12: 1.15,
    }[month_start.month]
    noise = rng.uniform(0.88, 1.12)
    return max(6, int(round(base * season * noise)))


def build_orders(customers, products):
    # Customer activity weights: a handful of heavy repeat buyers, a long tail
    # of occasional ones.
    weights = {}
    for c in customers:
        r = rng.random()
        if r < 0.12:
            weights[c[0]] = rng.uniform(7.0, 11.0)     # loyal core
        elif r < 0.45:
            weights[c[0]] = rng.uniform(2.5, 5.0)      # regulars
        else:
            weights[c[0]] = rng.uniform(0.5, 1.8)      # occasional
    signup = {c[0]: c[6] for c in customers}

    # Every real store has accounts that registered and never bought, and
    # catalogue lines that never moved. Without them the "never purchased" and
    # "never sold" anti-join reports come back empty and untested.
    non_buyers = set(rng.sample([c[0] for c in customers], 9))

    all_pids = list(range(1, len(PRODUCTS) + 1))
    never_sold = set(rng.sample(all_pids, 3))

    prod_ids = [p for p in all_pids if p not in never_sold]
    prod_weights = [PRODUCTS[p - 1][4] for p in prod_ids]
    prod_price = {pid: PRODUCTS[pid - 1][2] for pid in all_pids}

    orders, items, payments = [], [], []
    order_id = item_id = payment_id = 0

    for idx, ms in enumerate(month_starts(START, END)):
        target = monthly_order_target(ms, idx)
        for _ in range(target):
            days_in_month = ((ms.replace(day=28) + timedelta(days=4)).replace(day=1)
                             - ms).days
            order_date = ms + timedelta(days=rng.randint(0, days_in_month - 1))
            if order_date > END:
                continue

            eligible = [c[0] for c in customers
                        if signup[c[0]] <= order_date and c[0] not in non_buyers]
            if not eligible:
                continue
            cust = rng.choices(eligible, weights=[weights[c] for c in eligible])[0]

            order_id += 1

            # Basket: 1-5 distinct products, skewed towards small baskets.
            n_lines = rng.choices([1, 2, 3, 4, 5], weights=[38, 30, 18, 9, 5])[0]
            chosen = set()
            while len(chosen) < n_lines:
                chosen.add(rng.choices(prod_ids, weights=prod_weights)[0])

            total = Decimal("0.00")
            for pid in sorted(chosen):
                item_id += 1
                qty = rng.choices([1, 2, 3, 4], weights=[68, 21, 8, 3])[0]
                # unit_price is a snapshot, so allow a little drift from the
                # current catalogue price.
                factor = Decimal(rng.choice(["0.95", "1.00", "1.00", "1.00", "1.05"]))
                unit = money(prod_price[pid] * factor)
                disc = Decimal(rng.choices(["0.0000", "0.0500", "0.1000", "0.1500", "0.2000"],
                                           weights=[58, 15, 14, 8, 5])[0])
                line = money(qty * unit * (Decimal(1) - disc))
                total += line
                items.append((item_id, order_id, pid, qty, unit, disc))

            days_old = (END - order_date).days
            if days_old <= 6:
                status = rng.choices(["PLACED", "SHIPPED", "COMPLETED"],
                                     weights=[55, 30, 15])[0]
            elif days_old <= 20:
                status = rng.choices(["PLACED", "SHIPPED", "COMPLETED", "CANCELLED"],
                                     weights=[8, 27, 60, 5])[0]
            else:
                status = rng.choices(["COMPLETED", "CANCELLED", "RETURNED", "SHIPPED"],
                                     weights=[85, 6, 7, 2])[0]

            channel = rng.choice(CHANNELS)
            orders.append((order_id, cust, order_date, status, channel, total))

            # ---- payments -------------------------------------------------
            method = rng.choice(PAYMENT_METHODS)
            pay_date = order_date + timedelta(days=rng.choice([0, 0, 0, 1, 1, 2]))
            if pay_date > END:
                pay_date = END

            if status == "CANCELLED":
                # Either the payment never went through, or it was taken and
                # refunded. Some cancellations have no payment row at all.
                r = rng.random()
                if r < 0.45:
                    payment_id += 1
                    payments.append((payment_id, order_id, pay_date, total, method, "FAILED"))
                elif r < 0.80:
                    payment_id += 1
                    payments.append((payment_id, order_id, pay_date, total, method, "PAID"))
                    payment_id += 1
                    payments.append((payment_id, order_id,
                                     min(pay_date + timedelta(days=rng.randint(2, 9)), END),
                                     total, method, "REFUNDED"))
            elif status == "RETURNED":
                payment_id += 1
                payments.append((payment_id, order_id, pay_date, total, method, "PAID"))
                payment_id += 1
                payments.append((payment_id, order_id,
                                 min(pay_date + timedelta(days=rng.randint(5, 21)), END),
                                 total, method, "REFUNDED"))
            elif status == "PLACED":
                st = rng.choices(["PAID", "PENDING"], weights=[62, 38])[0]
                payment_id += 1
                payments.append((payment_id, order_id, pay_date, total, method, st))
            else:  # SHIPPED / COMPLETED
                if rng.random() < 0.06:      # a retry after a gateway failure
                    payment_id += 1
                    payments.append((payment_id, order_id, pay_date, total, method, "FAILED"))
                    pay_date = min(pay_date + timedelta(days=1), END)
                payment_id += 1
                payments.append((payment_id, order_id, pay_date, total, method, "PAID"))

    return orders, items, payments


# ----------------------------------------------------------------------
# SQL emitting helpers
# ----------------------------------------------------------------------

def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, date):
        return f"DATE '{v.isoformat()}'"
    if isinstance(v, (int, float, Decimal)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def emit(handle, table, columns, rows, chunk=50):
    handle.write(f"\n-- {table}: {len(rows)} rows\n")
    for i in range(0, len(rows), chunk):
        block = rows[i:i + chunk]
        handle.write(f"INSERT INTO {table} ({', '.join(columns)}) VALUES\n")
        handle.write(",\n".join("    (" + ", ".join(q(v) for v in r) + ")" for r in block))
        handle.write(";\n")


def main():
    customers = build_customers()
    products = build_products()
    orders, items, payments = build_orders(customers, products)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as f:
        f.write("-- ============================================================\n")
        f.write("-- Sales & Order Management Analytics System\n")
        f.write("-- File   : 02_seed_data.sql\n")
        f.write("-- Purpose: Sample transactional data\n")
        f.write("--\n")
        f.write("-- GENERATED FILE - do not edit by hand.\n")
        f.write("-- Regenerate with:  python tools/generate_seed_data.py\n")
        f.write(f"-- Random seed : {SEED}\n")
        f.write(f"-- Order window: {START} .. {END}\n")
        f.write("-- ============================================================\n")

        emit(f, "customers",
             ["customer_id", "name", "email", "phone", "city", "state", "signup_date"],
             customers)
        emit(f, "products",
             ["product_id", "product_name", "category", "price", "cost_price", "stock", "is_active"],
             products)
        emit(f, "orders",
             ["order_id", "customer_id", "order_date", "status", "channel", "total_amount"],
             orders, chunk=100)
        emit(f, "order_items",
             ["order_item_id", "order_id", "product_id", "quantity", "unit_price", "discount_pct"],
             items, chunk=100)
        emit(f, "payments",
             ["payment_id", "order_id", "payment_date", "amount", "method", "payment_status"],
             payments, chunk=100)

    print(f"wrote {OUT}")
    print(f"  customers   {len(customers):>6}")
    print(f"  products    {len(products):>6}")
    print(f"  orders      {len(orders):>6}")
    print(f"  order_items {len(items):>6}")
    print(f"  payments    {len(payments):>6}")


if __name__ == "__main__":
    main()
