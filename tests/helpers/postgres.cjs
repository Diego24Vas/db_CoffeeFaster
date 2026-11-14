const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');

module.exports = async function conBaseTemporal(nombre, prueba) {
  const container = process.env.TEST_POSTGRES_CONTAINER;
  const host = process.env.PGHOST || '';
  if (!container) assert.match(host, /^(localhost|127\.0\.0\.1|\/tmp\/[^\s]+)$/, 'PGHOST debe ser local');
  const database = `cf_${nombre}_test_${process.pid}_${Date.now()}`;
  const env = { ...process.env };
  for (const name of ['PGSERVICE', 'PGSERVICEFILE', 'PGHOSTADDR']) delete env[name];
  const comando = db => container
    ? ['docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-d', db, '-XAt', '-v', 'ON_ERROR_STOP=1']]
    : [process.env.TEST_PSQL || 'psql', ['-h', host, '-p', process.env.PGPORT || '5432', '-U', 'postgres', '-d', db, '-XAt', '-v', 'ON_ERROR_STOP=1']];
  const sql = (input, db = database) => {
    const [bin, args] = comando(db);
    return execFileSync(bin, args, { input, env, encoding: 'utf8', timeout: 30000, stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  };
  const sqlAsync = input => {
    const [bin, args] = comando(database);
    return new Promise((resolve, reject) => {
      const child = spawn(bin, args, { env, timeout: 30000 });
      let output = '', error = '';
      child.stdout.on('data', data => { output += data; });
      child.stderr.on('data', data => { error += data; });
      child.stdin.on('error', reject);
      child.on('error', reject);
      child.on('close', code => code === 0 ? resolve(output.trim()) : reject(new Error(error)));
      child.stdin.end(input);
    });
  };
  let creada = false;
  try {
    sql(`CREATE DATABASE ${database};`, 'postgres'); creada = true;
    await prueba({ sql, sqlAsync });
  } finally {
    if (creada) sql(`DROP DATABASE ${database} WITH (FORCE);`, 'postgres');
  }
};
