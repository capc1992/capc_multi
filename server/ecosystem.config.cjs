module.exports = {
  apps: [
    {
      name: 'capc-sync',
      cwd: __dirname,
      script: 'dist/src/main.js',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      restart_delay: 3000,
      max_memory_restart: '350M',
      kill_timeout: 10000,
      time: true,
      env: {
        NODE_ENV: 'production',
        HOST: '127.0.0.1',
        PORT: '3100',
      },
    },
  ],
};
