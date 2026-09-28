const sharedStyles = `
  :root{color-scheme:light;--navy:#142638;--green:#247452;--red:#b42318;--ink:#17212b;--muted:#52606d;--line:#d8e0e7;--surface:#fff;--bg:#f4f7f6}
  *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}
  main{width:min(720px,calc(100% - 32px));margin:48px auto}.brand{color:var(--green);font-weight:800;letter-spacing:.08em;text-transform:uppercase}
  h1{font-size:clamp(2rem,7vw,3.5rem);line-height:1.08;letter-spacing:-.035em;margin:.4rem 0 1rem}h2{line-height:1.2;margin-top:2rem}
  .card{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:clamp(20px,5vw,40px);box-shadow:0 12px 32px rgba(20,38,56,.08)}
  .notice{border-left:4px solid var(--green);background:#edf7f2;padding:12px 16px;border-radius:8px}.danger{border-left-color:var(--red);background:#fff1f0}
  label{display:block;font-weight:700;margin-top:18px}input{width:100%;min-height:48px;margin-top:6px;border:1px solid #aab7c2;border-radius:10px;padding:10px 12px;font:inherit}
  input:focus{outline:3px solid rgba(36,116,82,.25);border-color:var(--green)}button,.button{display:inline-flex;align-items:center;justify-content:center;min-height:48px;margin-top:24px;border:0;border-radius:10px;padding:12px 18px;background:var(--red);color:#fff;font:700 1rem system-ui;cursor:pointer;text-decoration:none}
  button:hover{background:#8f1c13}button:focus-visible,a:focus-visible{outline:3px solid #f4b740;outline-offset:3px}button:disabled{opacity:.55;cursor:not-allowed}
  a{color:#116447}.muted{color:var(--muted)}#result{margin-top:18px;font-weight:700}.footer{margin:24px 0;text-align:center;color:var(--muted)}
  @media(max-width:520px){main{margin:20px auto}.card{border-radius:14px}}
`;

export const accountDeletionPage = `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Eliminar cuenta — CAPC MULTISERVICIO</title><style>${sharedStyles}</style></head>
<body><main><article class="card"><div class="brand">CAPC MULTISERVICIO</div><h1>Eliminar cuenta remota</h1>
<p>Este formulario elimina permanentemente la cuenta remota del negocio y los datos sincronizados alojados por CAPC.</p>
<div class="notice danger"><strong>Esta acción no se puede deshacer.</strong> La base SQLite guardada en tus dispositivos no se elimina. Puedes conservarla por obligaciones contables o eliminar los datos locales desde la configuración del sistema.</div>
<form id="deletion-form">
<label for="email">Correo de la cuenta remota</label><input id="email" name="email" type="email" autocomplete="username" required maxlength="320">
<label for="password">Contraseña remota</label><input id="password" name="password" type="password" autocomplete="current-password" required maxlength="200">
<label for="business">ID del negocio <span class="muted">(opcional; necesario si el correo administra más de uno)</span></label><input id="business" name="business" inputmode="text" autocomplete="off" placeholder="00000000-0000-0000-0000-000000000000">
<label for="confirmation">Escribe ELIMINAR para confirmar</label><input id="confirmation" name="confirmation" autocomplete="off" required pattern="ELIMINAR">
<button id="submit" type="submit">Eliminar definitivamente</button><p id="result" role="status" aria-live="polite"></p>
</form><p><a href="/privacidad">Consultar la política de privacidad</a></p></article><p class="footer">CAPC MULTISERVICIO</p></main>
<script>
const form=document.getElementById('deletion-form');const result=document.getElementById('result');const button=document.getElementById('submit');
form.addEventListener('submit',async(event)=>{event.preventDefault();result.textContent='Procesando la solicitud…';button.disabled=true;
const business=document.getElementById('business').value.trim();const payload={email:document.getElementById('email').value.trim(),password:document.getElementById('password').value,confirmation:document.getElementById('confirmation').value.trim()};if(business)payload.business_id=business;
try{const response=await fetch('/api/v1/identity/delete-account',{method:'POST',headers:{'content-type':'application/json','accept':'application/json'},body:JSON.stringify(payload)});if(response.ok){form.reset();result.textContent='La cuenta remota y sus datos asociados fueron eliminados.';return;}const data=await response.json().catch(()=>({}));result.textContent=data.error==='business_id_required'?'Este correo administra más de un negocio. Indica el ID del negocio.':data.error==='rate_limited'?'Demasiados intentos. Espera antes de volver a intentar.':'No fue posible validar la cuenta. Revisa los datos ingresados.';}catch(_){result.textContent='No se pudo conectar. Intenta nuevamente cuando tengas internet.';}finally{button.disabled=false;}});
</script></body></html>`;

export const privacyPage = `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Política de privacidad — CAPC MULTISERVICIO</title><style>${sharedStyles}</style></head>
<body><main><article class="card"><div class="brand">CAPC MULTISERVICIO</div><h1>Política de privacidad</h1><p class="muted">Última actualización: 27 de septiembre de 2026.</p>
<h2>Datos locales</h2><p>Ventas, inventario, clientes, proveedores, caja y documentos se guardan en una base SQLite privada del dispositivo. CAPC no los recibe mientras la conexión remota esté desactivada.</p>
<h2>Conexión remota opcional</h2><p>Al activarla, se procesan el correo de acceso remoto, identificadores del negocio y dispositivos, operaciones sincronizadas y registros técnicos de seguridad. Las contraseñas locales y los códigos de recuperación offline nunca se transmiten.</p>
<h2>Uso y seguridad</h2><p>Los datos se utilizan para autenticar dispositivos, sincronizar información del negocio, prevenir abuso y mantener el servicio. Las contraseñas remotas y tokens se almacenan mediante hashes; las comunicaciones de producción deben usar HTTPS.</p>
<h2>Compartición</h2><p>CAPC no vende datos ni utiliza publicidad o seguimiento publicitario. El alojamiento técnico autorizado puede procesar datos únicamente para operar el servicio.</p>
<h2>Retención y eliminación</h2><p>La información remota se conserva mientras la cuenta exista. Al eliminarla se borran la identidad, sesiones, dispositivos y datos sincronizados. Registros locales permanecen en cada dispositivo y pueden estar sujetos a obligaciones contables del propietario.</p>
<p><a class="button" href="/eliminar-cuenta">Solicitar eliminación de cuenta</a></p>
<h2>Contacto de privacidad</h2><p>Para consultas de privacidad escribe a <a href="mailto:nicolasperdomoliz@gmail.com">nicolasperdomoliz@gmail.com</a>.</p>
</article><p class="footer">CAPC MULTISERVICIO</p></main></body></html>`;
