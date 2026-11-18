// Run against a disposable database that has migration 0001 applied:
//   TEST_DATABASE_URL=postgres://... npx vitest run tests/launch-allocation.concurrency.test.ts
// Needs: npm i -D vitest pg @types/pg
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL, max: 60 });
const CUSTOMERS = 150;
const CAPACITY = 100;

let launchId: string;
let customerIds: string[] = [];

async function one<T = any>(sql: string, params: unknown[] = []): Promise<T> {
  const { rows } = await pool.query(sql, params);
  return rows[0] as T;
}

beforeAll(async () => {
  const tag = Date.now().toString(36).toUpperCase().slice(-8);
  const region = await one(
    `insert into regions (code, name, country, status) values ($1, 'Test Region', 'Testland', 'published') returning id`,
    [`T${tag}`]
  );
  const launch = await one(
    `insert into launches (code, name, region_id, status, capacity)
     values ($1, 'Concurrency Test', $2, 'preorder_active', $3) returning id`,
    [`L${tag}`, region.id, CAPACITY]
  );
  launchId = launch.id;
  for (let i = 0; i < CUSTOMERS; i++) {
    const c = await one(`insert into customers (email) values ($1) returning id`, [`t${tag}-${i}@example.test`]);
    customerIds.push(c.id);
  }
});

afterAll(async () => {
  await pool.end();
});

describe("launch slot allocation", () => {
  it("reserves exactly 100 of 150 simultaneous customers", async () => {
    const results = await Promise.all(
      customerIds.map((id) =>
        one(`select * from reserve_launch_slot($1, $2, 15)`, [launchId, id])
      )
    );
    const reserved = results.filter((r) => r.r_result === "reserved").length;
    const full = results.filter((r) => r.r_result === "full").length;
    expect(reserved).toBe(CAPACITY);
    expect(full).toBe(CUSTOMERS - CAPACITY);
  });

  it("confirms all held slots concurrently without over-allocation and closes the launch", async () => {
    const holders = await pool.query(
      `select customer_id from slot_reservations where launch_id = $1 and status = 'active'`,
      [launchId]
    );
    const outcomes = await Promise.all(
      holders.rows.map((r) =>
        one(`select confirm_launch_slot($1, $2, null) as r`, [launchId, r.customer_id])
      )
    );
    expect(outcomes.filter((o) => o.r === "allocated").length).toBe(CAPACITY);

    const launch = await one(`select allocated_count, status, closed_at from launches where id = $1`, [launchId]);
    expect(launch.allocated_count).toBe(CAPACITY);
    expect(launch.status).toBe("closed");
    expect(launch.closed_at).not.toBeNull();
  });

  it("is idempotent: a retried webhook never creates a second slot", async () => {
    const holder = await one(`select customer_id from launch_participations where launch_id = $1 limit 1`, [launchId]);
    const again = await one(`select confirm_launch_slot($1, $2, null) as r`, [launchId, holder.customer_id]);
    expect(again.r).toBe("existing");
    const count = await one(`select count(*)::int as n from launch_participations where launch_id = $1`, [launchId]);
    expect(count.n).toBe(CAPACITY);
  });

  it("gives the 101st customer nothing once the launch is closed", async () => {
    const row = await one(
      `select c.id from customers c
       where c.id = any($1::uuid[])
         and not exists (select 1 from launch_participations p where p.launch_id = $2 and p.customer_id = c.id)
       limit 1`,
      [customerIds, launchId]
    );
    const reserve = await one(`select * from reserve_launch_slot($1, $2, 15)`, [launchId, row.id]);
    expect(reserve.r_result).toBe("closed");
    const confirm = await one(`select confirm_launch_slot($1, $2, null) as r`, [launchId, row.id]);
    expect(confirm.r).toBe("launch_unavailable");
  });
});
