function index(request) {
  const headersIn = request.headersIn;
  let headersKeys = [], headers = '';

  for (const key in headersIn) headersKeys.push(key);

  headersKeys.sort()

  for (const index in headersKeys) headers += `${headersKeys[index]}: ${headersIn[headersKeys[index]]}<br>`;

  let response = '<!DOCTYPE html><html><head><title>Debug</title></head><body><strong>HEADERS:</strong><pre>{headers}<pre></body></html>';
  response = response.replace('{headers}', headers || 'nothing');

  request.headersOut['Content-Type'] = 'text/html';
  request.return(200, response);
}

function secret(request) {
  let response = `Secret is: ${process.env.NGINX_SECRET_EXAMPLE ? process.env.NGINX_SECRET_EXAMPLE : 'UNKNOWN'}`;

  request.headersOut['Content-Type'] = 'text/html';
  request.return(200, response);
}

export default { index, secret };
